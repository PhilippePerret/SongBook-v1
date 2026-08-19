require "prawn"
require_relative "../../lib/kdp"

TRIM_W_IN = 8.27
TRIM_H_IN = 6.0
PAGE_COUNT = 24
PAPER = :white
# La marge de sécurité (1pt) est maintenant DANS la classe KDP (lib/kdp.rb) —
# plus besoin de coussin ici. "Bonne" page = pile sur la valeur renvoyée par la
# classe (offset 0) ; "mauvaise" page = 1pt au-delà, pour vérifier la détection.
GOOD_OFFSET_IN = 0.0
BAD_OFFSET_IN  = 1.0 / 72.0
CORNER_LINE_WIDTH_PT = 0.25 # trait fin : limite le débordement dû au centrage du trait sur son tracé

KDP_CALC = KDP.new(page_count: PAGE_COUNT, trim_width: TRIM_W_IN, trim_height: TRIM_H_IN, paper: PAPER, bleed: false)

FONT_DIR = File.expand_path("../../assets/fonts/HelveticaNeue", __dir__)

def in_pt(inches)
  inches * 72.0
end

def draw_margin_rect(pdf, kdp, page_no)
  w = in_pt(kdp.trim_width)
  h = in_pt(kdp.trim_height)
  x0 = in_pt(kdp.left_margin(page_no))
  x1 = w - in_pt(kdp.right_margin(page_no))
  y0 = in_pt(kdp.bottom_margin)
  y1 = h - in_pt(kdp.top_margin)
  pdf.dash(2, space: 2)
  pdf.stroke_color "999999"
  pdf.stroke_rectangle [x0, y1], x1 - x0, y1 - y0
  pdf.undash
  pdf.stroke_color "000000"
end

# Coin (bracket en L), sommet EXACTEMENT sur (x_in, y_in), branches vers l'intérieur
# de la page (dir_x/dir_y) uniquement — jamais vers l'extérieur. Sur une page bonne,
# aucune encre ne doit se trouver dans la marge KDP ; sur une page mauvaise, le sommet
# lui-même est dans la marge, donc de l'encre y est réellement présente.
def draw_corner(pdf, x_in, y_in, dir_x:, dir_y:, len: 14)
  x = in_pt(x_in)
  y = in_pt(y_in)
  pdf.stroke_color "000000"
  pdf.line [x, y], [x + dir_x * len, y]
  pdf.stroke
  pdf.line [x, y], [x, y + dir_y * len]
  pdf.stroke
end

# Repère textuel aligné à droite, PILE sur la vraie ligne de marge (x1_in), pour
# comparer visuellement à l'œil la position du coin (qui peut être décalé, sur les
# pages "mauvaises") par rapport à la limite réelle.
def draw_right_ref(pdf, x1_in, y_in, text)
  x1 = in_pt(x1_in)
  y = in_pt(y_in)
  pdf.text_box text, at: [0, y + 4], width: x1, align: :right, size: 8
end

Prawn::Document.generate(
  File.join(__dir__, "book_essai.pdf"),
  page_size: [in_pt(TRIM_W_IN), in_pt(TRIM_H_IN)],
  margin: 0
) do |pdf|
  pdf.font_families.update("HelveticaNeue" => {
    normal: File.join(FONT_DIR, "HelveticaNeue-Regular.ttf"),
    bold: File.join(FONT_DIR, "HelveticaNeue-Bold.ttf"),
    italic: File.join(FONT_DIR, "HelveticaNeue-Italic.ttf"),
    bold_italic: File.join(FONT_DIR, "HelveticaNeue-BoldItalic.ttf"),
  })
  pdf.font "HelveticaNeue"
  pdf.line_width CORNER_LINE_WIDTH_PT

  PAGE_COUNT.times do |i|
    page_no = i + 1
    pdf.start_new_page if i > 0

    bad_page = page_no > 12
    offset = bad_page ? BAD_OFFSET_IN : GOOD_OFFSET_IN

    left_m  = KDP_CALC.left_margin(page_no)
    right_m = KDP_CALC.right_margin(page_no)

    top_left_x     = left_m - offset
    top_right_x    = KDP_CALC.trim_width - right_m + offset
    top_y          = KDP_CALC.trim_height - KDP_CALC.top_margin + offset
    bottom_left_x  = top_left_x
    bottom_right_x = top_right_x
    bottom_y       = KDP_CALC.bottom_margin - offset

    corners = {
      "haut-gauche"  => [top_left_x, top_y, 1, -1],
      "haut-droite"  => [top_right_x, top_y, -1, -1],
      "bas-gauche"   => [bottom_left_x, bottom_y, 1, 1],
      "bas-droite"   => [bottom_right_x, bottom_y, -1, 1],
    }

    results = corners.map { |name, (x, y, _, _)| [name, KDP_CALC.inside_margins?(x, y, page_no: page_no)] }

    right_limit_x = KDP_CALC.trim_width - right_m

    draw_margin_rect(pdf, KDP_CALC, page_no)
    corners.each_value do |x, y, dir_x, dir_y|
      draw_corner(pdf, x, y, dir_x: dir_x, dir_y: dir_y)
    end
    draw_right_ref(pdf, right_limit_x, top_y - 20.0 / 72.0, "limite droite >")
    draw_right_ref(pdf, right_limit_x, bottom_y + 20.0 / 72.0, "limite droite >")

    side = KDP_CALC.recto?(page_no) ? "recto" : "verso"
    pdf.draw_text "Page #{page_no} (#{side}) — #{bad_page ? "coins à #{(BAD_OFFSET_IN * 72).round(2)}pt hors limite" : "coins à #{(-GOOD_OFFSET_IN * 72).round(2)}pt à l'intérieur de la limite"}",
      at: [in_pt(left_m), in_pt(KDP_CALC.trim_height) / 2 + 10], size: 10

    pdf.draw_text results.map { |name, ok| "#{name}: #{ok ? "OK" : "HORS LIMITE"}" }.join("  /  "),
      at: [in_pt(left_m), in_pt(KDP_CALC.trim_height) / 2 - 6], size: 10
  end
end

puts "book_essai.pdf généré, #{PAGE_COUNT} pages, marges #{KDP_CALC.margins}"
