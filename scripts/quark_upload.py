#!/usr/bin/env python3
"""把安装包传到夸克网盘指定文件夹（默认「影屿」），传完清掉旧版本。

一个文件开一次浏览器，避免多文件上传时进度条状态互相干扰；
是否传完不看页面文字，直接查云端文件列表核对大小。

用法：quark_upload.py --state /etc/yy-quark-state.json --folder <fid> file...
"""
import argparse
import asyncio
import json
import os
import re
import time

import requests
from playwright.async_api import async_playwright

UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)
BASE = "https://drive-pc.quark.cn/1/clouddrive"
QUERY = "pr=ucpro&fr=pc&uc_param_str="
FILE_TIMEOUT = 2400
STALL_SECONDS = 180


class Stalled(Exception):
    pass


def log(msg):
    print(f"{time.strftime('%H:%M:%S')} {msg}", flush=True)


def api(state_path):
    state = json.load(open(state_path))
    s = requests.Session()
    s.cookies.update({c["name"]: c["value"] for c in state["cookies"]})
    s.headers.update({"User-Agent": UA, "Referer": "https://pan.quark.cn/"})
    return s


def listing(s, folder):
    r = s.get(
        f"{BASE}/file/sort?{QUERY}&pdir_fid={folder}&_page=1&_size=200"
        "&_fetch_total=1&_fetch_sub_dirs=0&_sort=file_type:asc,updated_at:desc",
        timeout=60,
    ).json()
    return (r.get("data") or {}).get("list") or []


def tx_bytes():
    """网卡累计上行字节，用来判断上传是不是真的在走。"""
    try:
        route = open("/proc/net/route").read().splitlines()[1:]
        for line in route:
            parts = line.split()
            if parts[1] == "00000000":
                return int(open(f"/sys/class/net/{parts[0]}/statistics/tx_bytes").read())
    except Exception:
        pass
    return 0


def remove(s, fids):
    if not fids:
        return
    r = s.post(
        f"{BASE}/file/delete?{QUERY}",
        json={"action_type": 2, "filelist": list(fids), "exclude_fids": []},
        timeout=60,
    ).json()
    log(f"删除 {len(fids)} 个文件：{r.get('status')}")


async def counters(page):
    try:
        return await page.evaluate(
            """() => {
              const t = document.body.innerText;
              const m = t.match(/进行中\\s*(\\d+)[\\s\\S]{0,40}?已完成\\s*(\\d+)/);
              const speed = (t.match(/([\\d.]+\\s*[KMG]B\\/s)/) || [])[1] || '';
              const pcts = [...t.matchAll(/(\\d{1,3})%/g)].map((x) => Number(x[1]));
              const pct = pcts.length ? Math.max(...pcts) : -1;
              return { running: m ? Number(m[1]) : -1, done: m ? Number(m[2]) : -1, speed, pct };
            }"""
        )
    except Exception:
        return {"running": -1, "done": -1, "speed": "", "pct": -1}


async def push(path, folder, folder_name, state_path):
    """开一个浏览器把单个文件传上去，靠云端列表判断完成。"""
    name = os.path.basename(path)
    size = os.path.getsize(path)
    url = f"https://pan.quark.cn/list#/list/all/{folder}-{folder_name}"
    session = api(state_path)
    async with async_playwright() as p:
        browser = await p.chromium.launch(
            headless=True,
            args=[
                "--no-sandbox",
                "--disable-dev-shm-usage",
                "--disable-gpu",
                "--disable-background-timer-throttling",
                "--disable-backgrounding-occluded-windows",
                "--disable-renderer-backgrounding",
                "--disable-features=CalculateNativeWinOcclusion",
            ],
        )
        ctx = await browser.new_context(
            storage_state=state_path,
            user_agent=UA,
            viewport={"width": 1440, "height": 900},
            locale="zh-CN",
        )
        page = await ctx.new_page()
        await page.bring_to_front()
        await page.goto(url, wait_until="domcontentloaded", timeout=90000)
        await page.wait_for_timeout(8000)
        body = await page.evaluate("document.body.innerText")
        if "上传文件" not in body:
            await page.screenshot(path="/tmp/quark-page.png")
            await browser.close()
            raise SystemExit("页面没有上传按钮，可能登录态失效")
        async with page.expect_file_chooser(timeout=20000) as fc:
            await page.click("button:has-text('上传文件')")
        chooser = await fc.value
        await chooser.set_files([path])
        log(f"开始上传 {name}（{size/1048576:.1f}MB）")

        deadline = time.time() + FILE_TIMEOUT
        last = ""
        mark = (None, None)
        mark_at = time.time()
        last_sent = tx_bytes()
        while time.time() < deadline:
            hit = [i for i in listing(session, folder) if i["file_name"] == name]
            if hit and hit[0]["size"] == size:
                log(f"已确认 {name} {size}")
                await browser.close()
                return
            c = await counters(page)
            line = f"进行中 {c['running']} 已完成 {c['done']} {c['speed']} {c['pct']}%"
            if line != last:
                log(line)
                last = line
            sent = tx_bytes()
            if (c["pct"], c["done"]) != mark or sent - last_sent > 200 * 1024:
                mark, mark_at, last_sent = (c["pct"], c["done"]), time.time(), sent
            elif time.time() - mark_at > STALL_SECONDS:
                await page.screenshot(path="/tmp/quark-stall.png")
                await browser.close()
                raise Stalled(f"{name} 上传卡住（进度停在 {c['pct']}%）")
            await page.wait_for_timeout(6000)
        await page.screenshot(path="/tmp/quark-timeout.png")
        await browser.close()
        raise Stalled(f"{name} 上传超时")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", default="/etc/yy-quark-state.json")
    parser.add_argument("--folder", required=True)
    parser.add_argument("--folder-name", default="影屿")
    parser.add_argument("--keep", action="store_true")
    parser.add_argument("files", nargs="+")
    args = parser.parse_args()

    names = [os.path.basename(f) for f in args.files]
    for path in args.files:
        if not os.path.exists(path):
            raise SystemExit(f"文件不存在：{path}")

    session = api(args.state)
    items = listing(session, args.folder)
    # 同名文件和重复副本先删掉，否则夸克会存成「xxx(1).apk」
    junk = [
        i
        for i in items
        if i["file_name"] in names or re.match(r"^影屿-.*\(\d+\)", i["file_name"])
    ]
    remove(session, [i["fid"] for i in junk])

    for path in args.files:
        for attempt in range(1, 3):
            try:
                asyncio.run(push(path, args.folder, args.folder_name, args.state))
                break
            except Stalled as exc:
                log(f"第 {attempt} 次失败：{exc}")
                if attempt == 2:
                    raise SystemExit(str(exc))
                time.sleep(5)

    items = listing(session, args.folder)
    for name in names:
        hit = [i for i in items if i["file_name"] == name]
        want = os.path.getsize([f for f in args.files if os.path.basename(f) == name][0])
        if not hit or hit[0]["size"] != want:
            raise SystemExit(f"核对失败：{name}")
    if not args.keep:
        stale = [
            i
            for i in items
            if re.match(r"^影屿-\d", i["file_name"]) and i["file_name"] not in names
        ]
        remove(session, [i["fid"] for i in stale])
    log("DONE")


if __name__ == "__main__":
    main()
