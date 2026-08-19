require "prawn"
require_relative "../../lib/kdp"

TRIM_W_IN = 8.27
TRIM_H_IN = 11.69
PAGE_COUNT = 24
PAPER = :white

KDP_CALC = KDP.new(page_count: PAGE_COUNT, trim_width: TRIM_W_IN, trim_height: TRIM_H_IN, paper: PAPER, bleed: false)

FONT_DIR = File.expand_path("../../assets/fonts/HelveticaNeue", __dir__)
BLEED_IN = KDP::BLEED_IN

def in_pt(inches)
  inches * 72.0
end

# Texte centré PILE sur le point (x_in, y_in) — la moitié de sa hauteur/largeur
# déborde donc naturellement d'un côté. Objectif de Phil : tester si le
# vérificateur KDP réagit différemment à du vrai texte qu'à un simple trait
# vectoriel (coins précédents, jamais signalés).
def draw_straddle_text(pdf, x_in, y_in, text, w: 50, h: 16)
  x = in_pt(x_in)
  y = in_pt(y_in)
  pdf.fill_color "0000CC"
  pdf.text_box text, at: [x - w / 2.0, y + h / 2.0], width: w, height: h,
    align: :center, valign: :center, size: 11, style: :bold
  pdf.fill_color "000000"
end

Prawn::Document.generate(
  File.join(__dir__, "cover_essai-A4.pdf"),
  page_size: [in_pt(KDP_CALC.cover_width), in_pt(KDP_CALC.cover_height)],
  margin: 0
) do |pdf|
  pdf.font_families.update("HelveticaNeue" => {
    normal: File.join(FONT_DIR, "HelveticaNeue-Regular.ttf"),
    bold: File.join(FONT_DIR, "HelveticaNeue-Bold.ttf"),
  })
  pdf.font "HelveticaNeue"
  pdf.line_width 0.25

  cover_w = in_pt(KDP_CALC.cover_width)
  cover_h = in_pt(KDP_CALC.cover_height)
  bleed   = in_pt(BLEED_IN)
  spine_w = in_pt(KDP_CALC.spine_width)
  back_w  = in_pt(KDP_CALC.trim_width)
  front_w = in_pt(KDP_CALC.trim_width)

  # Zone de fond perdu (bord de la page, pas de trait — le bleed EST le bord du PDF).

  # Rectangle de rognage (trim) : à `bleed` de chaque bord.
  trim_x0 = bleed
  trim_x1 = cover_w - bleed
  trim_y0 = bleed
  trim_y1 = cover_h - bleed

  pdf.dash(3, space: 2)
  pdf.stroke_color "999999"
  pdf.stroke_rectangle [trim_x0, trim_y1], trim_x1 - trim_x0, trim_y1 - trim_y0
  pdf.undash

  # Repères d'angle façon imprimerie (petites croix hors bleed, aux 4 coins du trim).
  mark_len = 14
  mark_gap = 4
  pdf.stroke_color "000000"
  [[trim_x0, trim_y0], [trim_x1, trim_y0], [trim_x0, trim_y1], [trim_x1, trim_y1]].each do |x, y|
    dx = x == trim_x0 ? -1 : 1
    dy = y == trim_y0 ? -1 : 1
    pdf.line [x + dx * mark_gap, y], [x + dx * (mark_gap + mark_len), y]
    pdf.stroke
    pdf.line [x, y + dy * mark_gap], [x, y + dy * (mark_gap + mark_len)]
    pdf.stroke
  end

  # Séparation dos / plats, à l'intérieur du trim.
  spine_x0 = trim_x0 + back_w
  spine_x1 = spine_x0 + spine_w
  pdf.dash(2, space: 2)
  pdf.stroke_color "AAAAAA"
  pdf.stroke_line [spine_x0, trim_y0], [spine_x0, trim_y1]
  pdf.stroke_line [spine_x1, trim_y0], [spine_x1, trim_y1]
  pdf.undash
  pdf.stroke_color "000000"

  pdf.fill_color "000000"
  pdf.draw_text "4e de couverture", at: [trim_x0 + 20, trim_y1 - 30], size: 12
  pdf.draw_text "1re de couverture", at: [spine_x1 + 20, trim_y1 - 30], size: 12

  pdf.save_graphics_state do
    pdf.fill_color "000000"
    center_x = (spine_x0 + spine_x1) / 2.0
    center_y = cover_h / 2.0
    pdf.rotate(90, origin: [center_x, center_y]) do
      pdf.draw_text "Dos — #{PAGE_COUNT}p — #{KDP_CALC.spine_width.round(4)}in",
        at: [center_x - 70, center_y - 4], size: 8
    end
  end

  pdf.draw_text "Couverture #{KDP_CALC.cover_width.round(4)}in x #{KDP_CALC.cover_height.round(4)}in — bleed #{BLEED_IN}in — trim #{TRIM_W_IN}x#{TRIM_H_IN}in",
    at: [trim_x0 + 20, trim_y0 + 10], size: 8

  # Texte à cheval sur la limite de sécurité (0.125in du trim), au MILIEU de
  # chaque bord (pas aux coins) de chaque plat — moitié de l'encre dans la
  # bande interdite, moitié dans la zone sûre.
  safe = in_pt(KDP_CALC.cover_text_safe_margin)
  back_mid_x  = (trim_x0 + spine_x0) / 2.0
  front_mid_x = (spine_x1 + trim_x1) / 2.0
  mid_y       = (trim_y0 + trim_y1) / 2.0

  edges = {
    "4e haut"   => [back_mid_x, trim_y1 - safe],
    "4e bas"    => [back_mid_x, trim_y0 + safe],
    "4e gauche" => [trim_x0 + safe, mid_y],
    "4e droite" => [spine_x0 - safe, mid_y],
    "1re haut"   => [front_mid_x, trim_y1 - safe],
    "1re bas"    => [front_mid_x, trim_y0 + safe],
    "1re gauche" => [spine_x1 + safe, mid_y],
    "1re droite" => [trim_x1 - safe, mid_y],
  }
  in_pt_to_in = ->(v) { v / 72.0 }

  edges.each do |name, (x, y)|
    draw_straddle_text(pdf, in_pt_to_in.call(x), in_pt_to_in.call(y), "TEST")
    ok = KDP_CALC.inside_cover_safe_zone?(in_pt_to_in.call(x), in_pt_to_in.call(y))
    puts "#{name}: #{ok ? "OK (centre dans la zone sûre)" : "centre déjà hors zone sûre"}"
  end
end

puts "cover_essai-A4.pdf généré — #{KDP_CALC.cover_width.round(4)}in x #{KDP_CALC.cover_height.round(4)}in, dos #{KDP_CALC.spine_width.round(4)}in"
