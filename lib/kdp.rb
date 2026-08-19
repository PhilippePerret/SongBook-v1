# Calculs de gabarit imprimeur KDP (marges, dos, couverture).
# Sources : https://kdp.amazon.com/en_US/help/topic/GVBQ3CMEQW3W2VL6
#           https://kdp.amazon.com/en_US/help/topic/G201953020
class KDP
  BLEED_IN                    = 0.125
  OUTSIDE_MARGIN_NO_BLEED_MIN = 0.25
  OUTSIDE_MARGIN_BLEED_MIN    = 0.375

  COVER_TEXT_SAFE_MARGIN_MIN = 0.125
  SPINE_TEXT_SAFE_MARGIN_MIN = 0.0625

  # Minimums documentés par KDP, mais confirmés insuffisants par test réel
  # (essai KDP du 2026-08-17, format 8.27x6in/24p/blanc) : un élément posé
  # PILE sur ces valeurs est parfois signalé en erreur (arrondi côté KDP).
  # Toutes les valeurs publiques ci-dessous incluent donc déjà cette marge —
  # un appelant n'a jamais à rajouter de coussin lui-même.
  SAFETY_BUFFER_IN = 1.0 / 72.0

  SPINE_FACTOR = {
    white:          0.002252,
    cream:          0.0025,
    color_standard: 0.002252,
    color_premium:  0.002347,
  }.freeze

  # [page_count_min, page_count_max, gutter_in]
  GUTTER_RANGES = [
    [24,  150, 0.375],
    [151, 300, 0.5],
    [301, 500, 0.625],
    [501, 700, 0.75],
    [701, 828, 0.875],
  ].freeze

  attr_reader :page_count, :trim_width, :trim_height, :paper, :bleed

  def initialize(page_count:, trim_width:, trim_height:, paper: :white, bleed: false)
    @page_count  = page_count
    @trim_width  = trim_width
    @trim_height = trim_height
    @paper       = paper
    @bleed       = bleed
  end

  # --- Marges des pages intérieures ---

  def outside_margin
    (bleed ? OUTSIDE_MARGIN_BLEED_MIN : OUTSIDE_MARGIN_NO_BLEED_MIN) + SAFETY_BUFFER_IN
  end
  alias_method :top_margin, :outside_margin
  alias_method :bottom_margin, :outside_margin

  def gutter_margin
    range = GUTTER_RANGES.find { |min, max, _| page_count.between?(min, max) }
    raise ArgumentError, "page_count #{page_count} hors des plages KDP connues" unless range
    range[2] + SAFETY_BUFFER_IN
  end

  def margins
    { outside: outside_margin, top: top_margin, bottom: bottom_margin, gutter: gutter_margin }
  end

  # Convention livre : page impaire = recto (page de droite), reliure à gauche.
  # Page paire = verso (page de gauche), reliure à droite.
  def recto?(page_no)
    page_no.odd?
  end

  def verso?(page_no)
    !recto?(page_no)
  end

  def left_margin(page_no)
    recto?(page_no) ? gutter_margin : outside_margin
  end

  def right_margin(page_no)
    recto?(page_no) ? outside_margin : gutter_margin
  end

  # --- Couverture ---

  def cover_text_safe_margin
    COVER_TEXT_SAFE_MARGIN_MIN + SAFETY_BUFFER_IN
  end

  def spine_text_safe_margin
    SPINE_TEXT_SAFE_MARGIN_MIN + SAFETY_BUFFER_IN
  end

  def spine_width
    factor = SPINE_FACTOR.fetch(paper) { raise ArgumentError, "papier inconnu : #{paper.inspect}" }
    page_count * factor
  end

  def cover_width
    2 * BLEED_IN + 2 * trim_width + spine_width
  end

  def cover_height
    2 * BLEED_IN + trim_height
  end

  # --- Vérification (essais) ---

  # Un point (x, y) en pouces, origine en bas à gauche de la page intérieure,
  # doit-il être considéré comme respectant les marges ? `page_no` détermine
  # quel côté (gauche/droite) reçoit la marge de reliure (gutter).
  def inside_margins?(x, y, page_no:)
    x.between?(left_margin(page_no), trim_width - right_margin(page_no)) &&
      y.between?(bottom_margin, trim_height - top_margin)
  end

  # Un point (x, y) en pouces sur le fichier de couverture COMPLET (origine bas
  # gauche du fichier, bleed inclus), doit-il être considéré comme respectant
  # la zone de sécurité texte (0.125in du bord de rognage, plats ; 0.0625in de
  # chaque pli du dos, zone dos) ?
  def inside_cover_safe_zone?(x, y)
    trim_x0 = BLEED_IN
    trim_x1 = cover_width - BLEED_IN
    trim_y0 = BLEED_IN
    trim_y1 = cover_height - BLEED_IN
    return false unless x.between?(trim_x0, trim_x1) && y.between?(trim_y0, trim_y1)

    spine_x0 = trim_x0 + trim_width
    spine_x1 = spine_x0 + spine_width

    spine_safe = spine_text_safe_margin
    cover_safe = cover_text_safe_margin

    if x.between?(spine_x0, spine_x1)
      x.between?(spine_x0 + spine_safe, spine_x1 - spine_safe) &&
        y.between?(trim_y0 + cover_safe, trim_y1 - cover_safe)
    else
      x.between?(trim_x0 + cover_safe, trim_x1 - cover_safe) &&
        y.between?(trim_y0 + cover_safe, trim_y1 - cover_safe)
    end
  end
end
