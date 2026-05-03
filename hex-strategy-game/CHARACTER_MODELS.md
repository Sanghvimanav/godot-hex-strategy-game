# Creating Simple Character Sprites (Like Existing Units)

The existing units (peasant, scout, mage) use a simple 2D sprite workflow. Here's how to create similar characters:

## Asset Format

Each unit uses:
- **One PNG file** – horizontal sprite sheet (atlas) with 32×32 frames
- **SpriteFrames resource** (`.tres`) – defines animations by cropping regions from the atlas

## Sprite Sheet Layout

Frames are laid out **horizontally**, left to right, each 32×32 pixels:

| Frame 0 | Frame 1 | Frame 2 | ... |
|---------|---------|---------|-----|

Typical animations:
- **idle** – 2 frames, loop
- **attack** – ~10 frames, no loop
- **hit** – 2 frames, no loop
- **death** – 4 frames, no loop

## Step-by-Step: Create a New Unit

### 1. Create the PNG sprite sheet

- Use any tool: Aseprite, Piskel, GIMP, Photoshop, or even pixel-art generators
- Draw or place frames in a single horizontal strip, 32×32 per frame
- Save as PNG in `src/unit/art/<unit_name>/<unit_name>.png`
- Example size: 320×32 for 10 frames, or 128×32 for 4 animations × ~3 frames

### 2. Create the SpriteFrames resource

- In Godot: **Resource → New → SpriteFrames**
- Or duplicate an existing unit's `.tres` (e.g. `peasant_spriteframes.tres`)
- For each animation:
  - Add Animation
  - Add Frames: **Load** → select your PNG, then set **Region** for each frame (Rect2: x, y, 32, 32)
  - Set Loop / Speed as needed
- Save as `src/unit/art/<unit_name>/<unit_name>_spriteframes.tres`

### 3. Create the UnitDefinition

- Duplicate `peasant.tres` or another unit
- Set `frames` to your new SpriteFrames resource
- Set `move_action_keys` and `ability_action_keys` for this unit type

### 4. Reference in Unit scene

- The Unit scene uses `def.frames` – as long as your definition points to valid SpriteFrames, it will display

## Alternative: Simple Colored Shapes

For a **no-art** placeholder, you could:
- Use a `ColorRect` or `Polygon2D` as the unit visual
- Or use Godot's built-in 2D primitives (e.g. `draw_circle`)
- Override the sprite in code or use a minimal 1-frame SpriteFrames with a solid color texture

## Tools for Pixel Art

- **Aseprite** – popular for pixel art and animation
- **Piskel** – free, browser-based
- **LibreSprite** – Aseprite fork, open source
- **DALL-E / image generators** – can produce simple sprites if you describe "32x32 pixel character top-down view"
