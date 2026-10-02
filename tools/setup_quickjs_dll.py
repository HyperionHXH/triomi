"""把 flutter_js 自带的 Windows 原生库复制到项目根目录。

flutter test 在 Windows 上加载 `quickjs_c_bridge.dll` 时会搜索当前工作
目录（即项目根），而该库随包分发在 pub cache 的 windows/shared/ 下，
不会自动进入搜索路径——这就是 js_engine_probe_test 探测失败的唯一原因。

用法：python tools/setup_quickjs_dll.py
（升级 flutter_js 版本后需要重新执行。）
"""

import glob
import os
import shutil
import sys

PUB_CACHE_ROOTS = [
    os.path.join(os.environ.get("PUB_CACHE", ""), "hosted"),
    os.path.expanduser(r"~\AppData\Local\Pub\Cache\hosted"),
    os.path.expanduser(r"~/.pub-cache/hosted"),
]


def main() -> int:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    target = os.path.join(root, "quickjs_c_bridge.dll")
    if os.path.exists(target):
        print(f"已存在：{target}")
        return 0

    for base in PUB_CACHE_ROOTS:
        for pkg in glob.glob(os.path.join(base, "flutter_js-*")):
            candidate = os.path.join(pkg, "windows", "shared", "quickjs_c_bridge.dll")
            if os.path.exists(candidate):
                shutil.copy2(candidate, target)
                print(f"已复制：{candidate} -> {target}")
                return 0

    print("未找到 quickjs_c_bridge.dll：请先 flutter pub get 拉取 flutter_js，", file=sys.stderr)
    print("或从 flutter_js 包的 windows/shared/ 手动复制到项目根目录。", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
