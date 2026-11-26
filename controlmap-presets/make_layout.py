import json, sys

# GLFW keycodes / Amethyst special buttons
KEY = dict(SPACE=32, E=69, T=84, Q=81, F=70, ESC=256, TAB=258, F1=290, F2=291, F3=292, F5=294,
           LSHIFT=340)
KEYBOARD, MENU, VMOUSE = -1, -9, -5

def argb(v):  # unsigned 0xAARRGGBB -> signed int32 (Amethyst stores ints)
    return v - (1 << 32) if v >= (1 << 31) else v

BTN_BG   = argb(0x59000000)   # Roblox-like dark translucent
STROKE   = argb(0x80FFFFFF)

def button(name, keys, x, y, w, h, icon=None, game=True, menu=False, toggle=False, radius=40, stroke=1.5, bg=BTN_BG, iconOn=None):
    k = (keys + [0, 0, 0, 0])[:4]
    d = {
        "name": name, "keycodes": k, "dynamicX": x, "dynamicY": y,
        "width": w, "height": h, "opacity": 1, "cornerRadius": radius,
        "bgColor": bg, "strokeColor": STROKE, "strokeWidth": stroke,
        "isToggle": toggle, "isSwipeable": False, "passThruEnabled": False,
        "displayInGame": game, "displayInMenu": menu,
    }
    if icon:
        d["icon"] = icon
    if iconOn:
        d["iconOn"] = iconOn
    return d

def at(xdp):  # left offset in dp -> expression (px)
    return f"px({xdp})"

S = 60      # top bar button size (dp)
STEP = 68   # spacing
TOP = "px(10)"

controls = [
    # ---- top-left bar (in game) ----
    button("持ち物", [KEY["E"]], at(10 + STEP*1), TOP, S, S, icon="square.grid.3x3.fill"),
    button("チャット", [KEY["T"]], at(10 + STEP*2), TOP, S, S, icon="bubble.left.fill"),
    button("ポーズ", [KEY["ESC"]], at(10 + STEP*3), TOP, S, S, icon="pause.fill"),
    # ---- top-left bar (menus / inventory) ----
    button("✕", [KEY["ESC"]], at(10), TOP, S, S, icon="xmark", game=False, menu=True),
    button("キーボード", [KEYBOARD], at(10 + STEP*1), TOP, S, S, icon="keyboard", game=False, menu=True),
    # ---- right-thumb cluster (bigger, Roblox-like) ----
    button("しゃがむ", [KEY["LSHIFT"]], "${screen_width} - ${width} - px(60)",
           "${screen_height} - ${height} - px(176)", 80, 80, icon="arrow.down.to.line",
           menu=True, toggle=True, radius=100, stroke=2, bg=argb(0x99000000), iconOn="arrow.down.to.line.compact"),
    button("ダッシュ", [341], "${screen_width} - ${width} - px(188)",
           "${screen_height} - ${height} - px(176)", 80, 80, icon="tortoise.fill",
           toggle=True, radius=100, stroke=2, bg=argb(0x99000000), iconOn="hare.fill"),
    button("攻撃", [-3], "${screen_width} - ${width} - px(180)",
           "${screen_height} - ${height} - px(52)", 96, 96, icon="hammer.fill", radius=100, stroke=2,
           bg=argb(0x66000000)),
    button("ジャンプ", [KEY["SPACE"]], "${screen_width} - ${width} - px(40)",
           "${screen_height} - ${height} - px(40)", 120, 120, icon="arrow.up", radius=100, stroke=2,
           bg=argb(0x66000000)),
    # ---- menus only: right-click mode (half a stack / one item each) ----
    button("右クリック", [-10], at(10 + STEP*2), TOP, S, S, icon="cursorarrow.click.2",
           game=False, menu=True, toggle=True, bg=argb(0x99000000), iconOn="cursorarrow.click.2"),
]

# ---- "≡" drawer with everything else, opening downwards as a list ----
items = [
    ("視点切替 (F5)", [KEY["F5"]], False),
    ("プレイヤー一覧", [KEY["TAB"]], True),
    ("アイテムを捨てる", [KEY["Q"]], False),
    ("ブロックを複製 (中クリック)", [-6], False),
    ("左右の手を持ち替え", [KEY["F"]], False),
    ("HUD 表示切替 (F1)", [KEY["F1"]], False),
    ("デバッグ表示 (F3)", [KEY["F3"]], False),
    ("スクショ (F2)", [KEY["F2"]], False),
    ("マウス切替", [VMOUSE], False),
    ("ランチャーメニュー", [MENU], False),
]
sub = []
for i, (name, keys, toggle) in enumerate(items):
    sub.append(button(name, keys, at(10), f"px({10 + STEP + i*58})", 220, 52,
                      game=True, menu=False, toggle=toggle, radius=25))
drawer = {
    "orientation": "FREE",
    "properties": button("≡", [0], at(10), TOP, S, S, icon="line.3.horizontal"),
    "buttonProperties": sub,
}

# ---- Roblox-style dynamic thumbstick zone (bottom left) ----
joystick = button("button", [0], "px(0)", "${screen_height} - ${height}", 280, 560,
                  radius=0, stroke=0, bg=argb(0x40000000))
joystick.pop("isToggle"); joystick.pop("isSwipeable"); joystick.pop("passThruEnabled")
joystick.update({
    "strokeColor": argb(0x99FFFFFF),
    "forwardLock": False, "absolute": False,
    "floating": True, "stickSize": 150, "deadzone": 0.2,
    "autoSprint": False, "sprintThreshold": 0.9,
    "thumbColor": argb(0xDDFFFFFF), "idleOpacity": 0.6,
    "displayInGame": True, "displayInMenu": False,
})

STOCK = len(sys.argv) > 2 and sys.argv[2] == "stock"
if STOCK:
    # Works on the unmodified app: classic fixed stick, no Roblox-only keys
    joystick = {k: v for k, v in joystick.items() if k not in
                ("floating", "stickSize", "deadzone", "autoSprint", "sprintThreshold", "thumbColor", "idleOpacity")}
    joystick.update({"width": 190, "height": 190, "dynamicX": "px(40)",
                     "dynamicY": "${screen_height} - ${height} - px(40)",
                     "strokeColor": argb(0x99FFFFFF), "bgColor": argb(0x40000000)})

layout = {
    "version": 8, "scaledAt": 100,
    "mControlDataList": controls,
    "mDrawerDataList": [drawer],
    "mJoystickDataList": [joystick],
}
out = sys.argv[1]
with open(out, "w", encoding="utf-8") as f:
    json.dump(layout, f, ensure_ascii=False, indent=2)
print("wrote", out)
