extends RefCounted
## Shared flat UI style (panels, buttons, inputs) used across menus and battle HUD.
## Loaded via preload from `hex_ui_theme.gd` autoload (avoid class_name: autoload parses before global classes).

const C_BG := Color(0.04, 0.045, 0.065, 1)
const C_PANEL_MAIN := Color(0.1, 0.115, 0.145, 1)
const C_BORDER_MAIN := Color(0.22, 0.26, 0.34, 1)
const C_PANEL_WELL := Color(0.075, 0.085, 0.115, 1)
const C_BORDER_WELL := Color(0.18, 0.2, 0.27, 1)
const C_INSET := Color(0.08, 0.09, 0.125, 1)
const C_BORDER_INSET := Color(0.2, 0.23, 0.32, 1)


static func _sb_flat_margins(
	bg: Color,
	border: Color,
	radius: int,
	margin_l: int,
	margin_r: int,
	margin_t: int,
	margin_b: int,
) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(radius)
	s.set_border_width_all(1)
	s.border_color = border
	s.content_margin_left = margin_l
	s.content_margin_right = margin_r
	s.content_margin_top = margin_t
	s.content_margin_bottom = margin_b
	return s


static func _sb_flat(bg: Color, border: Color, radius: int, content_v: int = 12) -> StyleBoxFlat:
	return _sb_flat_margins(bg, border, radius, 14, 14, content_v, content_v)


static func _sb_primary_normal() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.28, 0.52, 0.95, 1)
	s.set_corner_radius_all(10)
	s.content_margin_left = 22
	s.content_margin_right = 22
	s.content_margin_top = 10
	s.content_margin_bottom = 10
	return s


static func build() -> Theme:
	var t := Theme.new()
	t.default_font_size = 14

	# --- PanelContainer / Panel (HUD cards, form sections)
	var sb_well := _sb_flat(C_PANEL_WELL, C_BORDER_WELL, 12, 12)
	t.set_stylebox("panel", "PanelContainer", sb_well)
	t.set_stylebox("panel", "Panel", sb_well)

	t.set_type_variation(&"UiMainCard", &"PanelContainer")
	var sb_main := _sb_flat_margins(C_PANEL_MAIN, C_BORDER_MAIN, 18, 0, 0, 0, 0)
	sb_main.content_margin_left = 0
	sb_main.content_margin_right = 0
	sb_main.content_margin_top = 0
	sb_main.content_margin_bottom = 0
	sb_main.shadow_color = Color(0, 0, 0, 0.45)
	sb_main.shadow_size = 14
	sb_main.shadow_offset = Vector2(0, 6)
	t.set_stylebox("panel", "UiMainCard", sb_main)

	t.set_type_variation(&"UiInsetStrip", &"PanelContainer")
	var sb_inset := _sb_flat(C_INSET, C_BORDER_INSET, 10, 12)
	sb_inset.content_margin_left = 0
	sb_inset.content_margin_right = 0
	sb_inset.content_margin_top = 0
	sb_inset.content_margin_bottom = 0
	t.set_stylebox("panel", "UiInsetStrip", sb_inset)

	# --- Buttons (secondary default)
	var bn := _sb_flat(Color(0.15, 0.17, 0.23, 1), Color(0.26, 0.29, 0.38, 1), 10, 10)
	var bh: StyleBoxFlat = bn.duplicate()
	bh.bg_color = Color(0.19, 0.21, 0.28, 1)
	var bp: StyleBoxFlat = bn.duplicate()
	bp.bg_color = Color(0.12, 0.14, 0.19, 1)
	var bdis: StyleBoxFlat = bn.duplicate()
	bdis.bg_color = Color(0.1, 0.11, 0.14, 1)
	bdis.border_color = Color(0.18, 0.18, 0.2, 1)
	var bf: StyleBoxFlat = bn.duplicate()
	bf.set_border_width_all(2)
	bf.border_color = Color(0.55, 0.72, 1, 0.75)
	for k in ["normal", "hover", "pressed", "disabled", "focus"]:
		var sb: StyleBoxFlat = bn
		match k:
			"hover":
				sb = bh
			"pressed":
				sb = bp
			"disabled":
				sb = bdis
			"focus":
				sb = bf
		t.set_stylebox(StringName(k), "Button", sb)
	t.set_color("font_color", "Button", Color(0.88, 0.9, 0.95))
	t.set_color("font_hover_color", "Button", Color(0.98, 0.99, 1))
	t.set_color("font_pressed_color", "Button", Color(0.95, 0.96, 0.98))
	t.set_color("font_disabled_color", "Button", Color(0.45, 0.47, 0.52))
	t.set_font_size("font_size", "Button", 14)

	t.set_type_variation(&"PrimaryButton", &"Button")
	var pn := _sb_primary_normal()
	var ph: StyleBoxFlat = pn.duplicate()
	ph.bg_color = Color(0.38, 0.62, 1, 1)
	var pp: StyleBoxFlat = pn.duplicate()
	pp.bg_color = Color(0.22, 0.42, 0.82, 1)
	var pf: StyleBoxFlat = pn.duplicate()
	pf.set_border_width_all(2)
	pf.border_color = Color(0.75, 0.88, 1, 0.55)
	t.set_stylebox("normal", "PrimaryButton", pn)
	t.set_stylebox("hover", "PrimaryButton", ph)
	t.set_stylebox("pressed", "PrimaryButton", pp)
	t.set_stylebox("disabled", "PrimaryButton", bdis)
	t.set_stylebox("focus", "PrimaryButton", pf)
	t.set_color("font_color", "PrimaryButton", Color(1, 1, 1))
	t.set_color("font_hover_color", "PrimaryButton", Color(1, 1, 1))
	t.set_color("font_pressed_color", "PrimaryButton", Color(0.95, 0.97, 1))
	t.set_color("font_disabled_color", "PrimaryButton", Color(0.55, 0.58, 0.65))
	t.set_font_size("font_size", "PrimaryButton", 15)

	t.set_type_variation(&"ScenarioToggle", &"Button")
	var sn := _sb_flat(Color(0.14, 0.16, 0.21, 1), Color(0.24, 0.27, 0.35, 1), 9, 10)
	var sh: StyleBoxFlat = sn.duplicate()
	sh.bg_color = Color(0.18, 0.2, 0.26, 1)
	var sp: StyleBoxFlat = sn.duplicate()
	sp.bg_color = Color(0.26, 0.48, 0.86, 1)
	sp.border_color = Color(0.45, 0.68, 1, 0.85)
	var sf: StyleBoxFlat = sn.duplicate()
	sf.set_border_width_all(2)
	sf.border_color = Color(0.55, 0.72, 1, 0.75)
	t.set_stylebox("normal", "ScenarioToggle", sn)
	t.set_stylebox("hover", "ScenarioToggle", sh)
	t.set_stylebox("pressed", "ScenarioToggle", sp)
	t.set_stylebox("disabled", "ScenarioToggle", bdis)
	t.set_stylebox("focus", "ScenarioToggle", sf)
	t.set_color("font_color", "ScenarioToggle", Color(0.9, 0.92, 0.96))
	t.set_color("font_hover_color", "ScenarioToggle", Color(0.98, 0.99, 1))
	t.set_color("font_pressed_color", "ScenarioToggle", Color(1, 1, 1))
	t.set_font_size("font_size", "ScenarioToggle", 14)

	# --- LineEdit
	var le := _sb_flat(Color(0.12, 0.14, 0.19, 1), Color(0.22, 0.25, 0.33, 1), 8, 8)
	var lef: StyleBoxFlat = le.duplicate()
	lef.set_border_width_all(2)
	lef.border_color = Color(0.45, 0.62, 0.95, 0.7)
	t.set_stylebox("normal", "LineEdit", le)
	t.set_stylebox("read_only", "LineEdit", le.duplicate())
	t.set_stylebox("focus", "LineEdit", lef)
	t.set_color("font_color", "LineEdit", Color(0.9, 0.92, 0.96))
	t.set_color("font_placeholder_color", "LineEdit", Color(0.45, 0.48, 0.55))
	t.set_color("font_uneditable_color", "LineEdit", Color(0.55, 0.58, 0.65))
	t.set_color("caret_color", "LineEdit", Color(0.92, 0.94, 1))
	t.set_font_size("font_size", "LineEdit", 13)

	# --- OptionButton
	var obn := le.duplicate()
	var obh: StyleBoxFlat = obn.duplicate()
	obh.bg_color = Color(0.16, 0.18, 0.24, 1)
	t.set_stylebox("normal", "OptionButton", obn)
	t.set_stylebox("hover", "OptionButton", obh)
	t.set_stylebox("pressed", "OptionButton", obh)
	t.set_color("font_color", "OptionButton", Color(0.88, 0.9, 0.95))
	t.set_font_size("font_size", "OptionButton", 13)

	# --- Labels
	t.set_color("font_color", "Label", Color(0.9, 0.92, 0.96))
	t.set_font_size("font_size", "Label", 14)

	t.set_type_variation(&"UiTitle", &"Label")
	t.set_color("font_color", "UiTitle", Color(0.97, 0.98, 1, 1))
	t.set_font_size("font_size", "UiTitle", 26)

	t.set_type_variation(&"UiHeading", &"Label")
	t.set_color("font_color", "UiHeading", Color(0.94, 0.95, 0.98, 1))
	t.set_font_size("font_size", "UiHeading", 18)

	t.set_type_variation(&"UiSubtitle", &"Label")
	t.set_color("font_color", "UiSubtitle", Color(0.55, 0.58, 0.68, 1))
	t.set_font_size("font_size", "UiSubtitle", 14)

	t.set_type_variation(&"UiFormLabel", &"Label")
	t.set_color("font_color", "UiFormLabel", Color(0.62, 0.66, 0.78, 1))
	t.set_font_size("font_size", "UiFormLabel", 12)

	t.set_type_variation(&"UiHint", &"Label")
	t.set_color("font_color", "UiHint", Color(0.55, 0.58, 0.68, 1))
	t.set_font_size("font_size", "UiHint", 11)

	t.set_type_variation(&"UiStatusOk", &"Label")
	t.set_color("font_color", "UiStatusOk", Color(0.55, 0.72, 0.55, 1))
	t.set_font_size("font_size", "UiStatusOk", 12)

	t.set_type_variation(&"UiBanner", &"Label")
	t.set_color("font_color", "UiBanner", Color(0.78, 0.82, 0.92, 1))
	t.set_font_size("font_size", "UiBanner", 13)

	t.set_type_variation(&"UiLlmHud", &"Label")
	t.set_color("font_color", "UiLlmHud", Color(0.75, 0.8, 0.95, 1))
	t.set_font_size("font_size", "UiLlmHud", 11)

	# --- HSeparator
	var sep := StyleBoxFlat.new()
	sep.bg_color = Color(0.22, 0.26, 0.34, 0.85)
	sep.set_corner_radius_all(1)
	t.set_stylebox("separator", "HSeparator", sep)

	# --- PopupMenu (OptionButton dropdowns)
	var pop := _sb_flat_margins(Color(0.1, 0.11, 0.15, 1), C_BORDER_WELL, 8, 6, 6, 6, 6)
	pop.content_margin_left = 4
	pop.content_margin_right = 4
	t.set_stylebox("panel", "PopupMenu", pop)
	t.set_color("font_color", "PopupMenu", Color(0.9, 0.92, 0.96))
	t.set_color("font_hover_color", "PopupMenu", Color(1, 1, 1))
	t.set_color("font_accelerator_color", "PopupMenu", Color(0.55, 0.58, 0.68))
	t.set_color("font_separator_color", "PopupMenu", Color(0.4, 0.42, 0.48))

	return t
