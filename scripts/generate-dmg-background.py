#!/usr/bin/env python3
"""Generate the DMG background image and orange Applications icon for Stubble.

Creates a 600×400 background that matches the DMG window size 1:1.
  - Off-white warm cream background
  - Stubble logo (orb + wordmark) centered near the top
  - Subtle dotted arrow between icon positions (arrowhead follows curve)
  - "Drag to Applications" label

Also generates an orange-tinted Applications folder icon from the macOS
system icon for brand consistency.

Icon positions match create-dmg layout (point coords):
  App icon at (150, 200) — left side
  Applications at (450, 200) — right side
"""

from PIL import Image, ImageDraw, ImageFont, ImageEnhance
import math
import os
import subprocess
import tempfile

WIDTH, HEIGHT = 600, 400
BG_COLOR = (247, 247, 243)  # warm cream
TEXT_MUTED = (170, 170, 162)
ARROW_COLOR = (195, 195, 187)

# Icon center positions (1x point coords, matching create-dmg)
APP_X, APP_Y = 150, 200
APPS_X, APPS_Y = 450, 200

script_dir = os.path.dirname(os.path.abspath(__file__))
project_dir = os.path.join(script_dir, "..")
output_dir = os.path.join(project_dir, "Resources")
os.makedirs(output_dir, exist_ok=True)

# ═══════════════════════════════════════════════════════════════
# Part 1: DMG Background
# ═══════════════════════════════════════════════════════════════

img = Image.new("RGBA", (WIDTH, HEIGHT), (*BG_COLOR, 255))
draw = ImageDraw.Draw(img)

# ─── Load and place the Stubble logo ─────────────────────────
logo_path = os.path.expanduser("~/StubbleApp/logo.png")
resources_logo = os.path.join(output_dir, "logo.png")
if not os.path.exists(logo_path):
    logo_path = resources_logo

if os.path.exists(logo_path):
    logo = Image.open(logo_path).convert("RGBA")

    # Scale logo to fit — target ~160px wide for 600px canvas
    target_width = 160
    scale = target_width / logo.width
    new_size = (int(logo.width * scale), int(logo.height * scale))
    logo = logo.resize(new_size, Image.LANCZOS)

    # Center horizontally, position near the top
    logo_x = (WIDTH - logo.width) // 2
    logo_y = 28
    img.paste(logo, (logo_x, logo_y), logo)

    # Copy logo to Resources if it's not there yet
    if not os.path.exists(resources_logo) and os.path.exists(os.path.expanduser("~/StubbleApp/logo.png")):
        import shutil
        shutil.copy2(os.path.expanduser("~/StubbleApp/logo.png"), resources_logo)

    draw = ImageDraw.Draw(img)

# ─── Font loading ────────────────────────────────────────────
def get_font(size, bold=False):
    paths = [
        "/System/Library/Fonts/SFPro-Bold.otf" if bold else "/System/Library/Fonts/SFPro-Regular.otf",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf" if bold else "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
    ]
    for p in paths:
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except Exception:
                continue
    return ImageFont.load_default()

font_label = get_font(13)

# ─── Dotted curved arrow between icon positions ─────────────
arrow_start_x = APP_X + 60   # right edge of app icon area
arrow_end_x = APPS_X - 60    # left edge of Applications icon area
arrow_y = APP_Y - 15         # slightly above icon centers
arc_height = -18

num_dots = 24
for i in range(num_dots):
    t = i / num_dots
    x = arrow_start_x + (arrow_end_x - arrow_start_x) * t
    y = arrow_y + arc_height * math.sin(t * math.pi)

    dot_size = 1.2 + 0.8 * math.sin(t * math.pi)
    alpha = 0.3 + 0.6 * math.sin(t * math.pi)
    color = tuple(int(BG_COLOR[c] * (1 - alpha) + ARROW_COLOR[c] * alpha) for c in range(3))

    draw.ellipse(
        [x - dot_size, y - dot_size, x + dot_size, y + dot_size],
        fill=(*color, 255)
    )

# ─── Arrowhead (rotated to follow the curve's tangent) ──────
# The arc descends at the end, so the arrowhead should angle downward.
# At t≈1: dy/dt = arc_height * π * cos(π) > 0 (pointing down-right).
# User requested ~10° tilt to match the visual curve.
angle_deg = 10
angle_rad = math.radians(angle_deg)

ah_x = arrow_end_x + 2
ah_y = arrow_y
arrow_size = 6

# Direction vector (tip points this way)
dx = math.cos(angle_rad)
dy = math.sin(angle_rad)
# Perpendicular vector
px = -math.sin(angle_rad)
py = math.cos(angle_rad)

# Tip, and two base corners
tip = (ah_x, ah_y)
base1 = (ah_x - arrow_size * dx + arrow_size * 0.6 * px,
         ah_y - arrow_size * dy + arrow_size * 0.6 * py)
base2 = (ah_x - arrow_size * dx - arrow_size * 0.6 * px,
         ah_y - arrow_size * dy - arrow_size * 0.6 * py)

draw.polygon([tip, base1, base2], fill=(*ARROW_COLOR, 255))

# ─── "Drag to Applications" label centered below icons ──────
label_text = "Drag to Applications"
bbox = draw.textbbox((0, 0), label_text, font=font_label)
lw = bbox[2] - bbox[0]
label_x = (WIDTH - lw) / 2
label_y = APP_Y + 72
draw.text((label_x, label_y), label_text, fill=(*TEXT_MUTED, 255), font=font_label)

# ─── Save background ─────────────────────────────────────────
bg_path = os.path.join(output_dir, "dmg-background.png")
img.convert("RGB").save(bg_path, "PNG")
print(f"✅ DMG background saved: {bg_path}")
print(f"   Size: {WIDTH}×{HEIGHT} (1:1 with DMG window)")

# ═══════════════════════════════════════════════════════════════
# Part 2: Orange-tinted Applications folder icon
# ═══════════════════════════════════════════════════════════════

SYSTEM_APPS_ICON = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/ApplicationsFolderIcon.icns"
ORANGE_ICON_PATH = os.path.join(output_dir, "applications-icon-orange.png")

# Stubble brand orange — sampled from the orb in the logo
# Shadows → deep orange, midtones → the exact orb orange, highlights → warm peach
ORANGE_SHADOW = (140, 40, 10)
ORANGE_MID    = (236, 78, 32)    # exact Stubble orb orange (sampled from logo)
ORANGE_HIGH   = (255, 180, 130)

if os.path.exists(SYSTEM_APPS_ICON):
    try:
        from PIL import ImageOps

        # Extract the 512×512 representation from .icns via sips
        with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as tmp:
            tmp_path = tmp.name

        subprocess.run([
            "sips", "-s", "format", "png",
            "--resampleHeight", "512",
            SYSTEM_APPS_ICON, "--out", tmp_path
        ], capture_output=True)

        icon_img = Image.open(tmp_path).convert("RGBA")
        os.unlink(tmp_path)

        # Separate alpha channel, colorize the RGB, then reapply alpha
        r, g, b, a = icon_img.split()
        gray = icon_img.convert("L")

        # Colorize: maps black→shadow, mid-gray→mid, white→highlight
        colorized = ImageOps.colorize(
            gray,
            black=ORANGE_SHADOW,
            mid=ORANGE_MID,
            white=ORANGE_HIGH,
        )

        # Reapply original alpha
        orange_icon = colorized.convert("RGBA")
        orange_icon.putalpha(a)

        orange_icon.save(ORANGE_ICON_PATH, "PNG")
        print(f"✅ Orange Applications icon saved: {ORANGE_ICON_PATH}")

    except Exception as e:
        print(f"⚠️  Could not generate orange icon: {e}")
else:
    print(f"⚠️  System Applications icon not found at {SYSTEM_APPS_ICON}")
