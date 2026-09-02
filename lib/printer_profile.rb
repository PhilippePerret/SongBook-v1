require_relative "app_config"

# Calculs de gabarit imprimeur (marges, dos, couverture). Marges intérieures
# configurables (`.infos` du carnet), KDP = preset par défaut seulement.
# `facing_pages:` choisit le vocabulaire des marges latérales : true -> `outside_margin:`/
# `gutter_margin:` (alterne recto/verso) ; false -> `left_margin:`/`right_margin:` (fixes).
# Sources KDP : https://kdp.amazon.com/en_US/help/topic/GVBQ3CMEQW3W2VL6
#               https://kdp.amazon.com/en_US/help/topic/G201953020
#               https://kdp.amazon.com/en_US/help/topic/G5HDYGP4BXLX4RUW (barcode)
class PrinterProfile
  DEFAULT_PAPER = :white
  DEFAULT_BLEED = false

  BLEED_IN                    = 0.125
  OUTSIDE_MARGIN_NO_BLEED_MIN = 0.25
  OUTSIDE_MARGIN_BLEED_MIN    = 0.375

  COVER_TEXT_SAFE_MARGIN_MIN = 0.125
  SPINE_TEXT_SAFE_MARGIN_MIN = 0.0625

  # Zone réservée au code-barres ISBN, 4e de couverture (KDP fournit son propre
  # code-barres gratuit si aucun ISBN propre n'est fourni — la zone reste
  # réservée dans les deux cas).
  BARCODE_WIDTH_IN     = 2.0
  BARCODE_HEIGHT_IN    = 1.2
  BARCODE_WIDTH_MIN_IN = 1.4
  BARCODE_HEIGHT_MIN_IN = 0.8
  BARCODE_MARGIN_IN    = 0.25

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

  DEFAULT_FACING_PAGES = true

  attr_reader :page_count, :trim_width, :trim_height, :paper, :bleed, :facing_pages

  # Overrides en pouces, `nil` = calcul du profil imprimeur (KDP pour l'instant).
  def initialize(page_count:, trim_width:, trim_height:, paper: DEFAULT_PAPER, bleed: DEFAULT_BLEED,
      facing_pages: DEFAULT_FACING_PAGES, outside_margin: nil, gutter_margin: nil, top_margin: nil, bot_margin: nil,
      left_margin: nil, right_margin: nil)
    @page_count  = page_count
    @trim_width  = trim_width
    @trim_height = trim_height
    @paper       = paper
    @bleed       = bleed
    @facing_pages = facing_pages
    @outside_margin_override = outside_margin
    @gutter_margin_override  = gutter_margin
    @top_margin_override     = top_margin
    @bot_margin_override     = bot_margin
    @left_margin_override    = left_margin
    @right_margin_override   = right_margin
  end

  # --- Marges des pages intérieures ---

  def outside_margin
    @outside_margin_override || ((bleed ? OUTSIDE_MARGIN_BLEED_MIN : OUTSIDE_MARGIN_NO_BLEED_MIN) + SAFETY_BUFFER_IN)
  end

  def top_margin
    @top_margin_override || outside_margin
  end

  def bot_margin
    @bot_margin_override || outside_margin
  end

  # Hors plages connues (page_count < 24 ou > 828) : jamais bloquant — accroché à la
  # plage la plus proche plutôt qu'une exception (avertissement laissé à l'appelant,
  # `CarnetBuilder.build`, seul à savoir si l'imprimeur visé est concerné).
  def gutter_margin
    @gutter_margin_override || begin
      range = GUTTER_RANGES.find { |min, max, _| page_count.between?(min, max) } ||
        (page_count < GUTTER_RANGES.first[0] ? GUTTER_RANGES.first : GUTTER_RANGES.last)
      range[2] + SAFETY_BUFFER_IN
    end
  end

  def self.page_count_range
    [GUTTER_RANGES.first[0], GUTTER_RANGES.last[1]]
  end

  # Marges fixes (facing_pages: false) : défaut = outside_margin (symétrique, pas de dos).
  def left_margin_value
    @left_margin_override || outside_margin
  end

  def right_margin_value
    @right_margin_override || outside_margin
  end

  # Lit les `*_margin:` d'un `.infos` déjà parsé (clés premier niveau), convertit en
  # pouces — `nil` par clé absente, à passer tel quel aux kwargs `.new` correspondants.
  def self.margin_overrides(conf)
    { outside_margin: conf["outside_margin"], gutter_margin: conf["gutter_margin"],
      top_margin: conf["top_margin"], bot_margin: conf["bot_margin"],
      left_margin: conf["left_margin"], right_margin: conf["right_margin"] }
      .transform_values { |v| v.nil? ? nil : AppConfig.length_in(v) }
  end

  def self.facing_pages(conf)
    conf.key?("facing_pages") ? conf["facing_pages"] == true : DEFAULT_FACING_PAGES
  end

  def margins
    { outside: outside_margin, top: top_margin, bot: bot_margin, gutter: gutter_margin }
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
    return left_margin_value unless facing_pages

    recto?(page_no) ? gutter_margin : outside_margin
  end

  def right_margin(page_no)
    return right_margin_value unless facing_pages

    recto?(page_no) ? outside_margin : gutter_margin
  end

  # --- Couverture ---

  def cover_text_safe_margin
    COVER_TEXT_SAFE_MARGIN_MIN + SAFETY_BUFFER_IN
  end

  def spine_text_safe_margin
    SPINE_TEXT_SAFE_MARGIN_MIN + SAFETY_BUFFER_IN
  end

  # Zone code-barres ISBN, bas droite de la 4e de couverture (bord adjacent
  # au dos) — coordonnées en pouces, origine bas gauche du fichier couverture
  # complet (bleed inclus), même repère que `inside_cover_safe_zone?`.
  def barcode_zone(width: BARCODE_WIDTH_IN, height: BARCODE_HEIGHT_IN)
    spine_x0 = BLEED_IN + trim_width
    x1 = spine_x0 - BARCODE_MARGIN_IN
    x0 = x1 - width
    y0 = BLEED_IN + BARCODE_MARGIN_IN
    y1 = y0 + height
    { x0: x0, y0: y0, x1: x1, y1: y1 }
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
      y.between?(bot_margin, trim_height - top_margin)
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
