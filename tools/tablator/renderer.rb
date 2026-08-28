# frozen_string_literal: true

# tools/tablator/renderer.rb : rendu SVG géométrique direct (pas de moteur de
# notation externe) d'une tablature déjà parsée en mesures
# (`Tablator.parse_measures`, voir `parser.rb`). Aucune logique de lecture/
# syntaxe ici — séparé pour limiter les collisions d'édition entre "comment on
# LIT une tablature" et "comment on la DESSINE" (Phil, 2026-08-28).

module Tablator
  TAB_LINES = 6
  LINE_SPACING = 8.0        # écart entre deux lignes de corde (pt)
  STAFF_HEIGHT = LINE_SPACING * (TAB_LINES - 1)
  NUMBER_SIZE = 6.5
  STEM_HEIGHT = 8.0         # hauteur du jambage au-dessus de la ligne du haut
  FLAG_LEN = 3.5
  FLAG_GAP = 2.5            # écart vertical entre deux crochets empilés (double/triple croche)
  CHORD_NAME_SIZE = 7.0
  ROW_GAP = 2.5
  FINGER_SIZE = 6.0
  TIME_SIG_W = 15.0         # marge gauche réservée à l'indicatif (tous systèmes, aligné)
  BEAT_WIDTH = 20.0         # largeur (pt) d'un temps (noire) — LE réglage taille/densité
  NOTE_INSET = 6.0          # marge évitant qu'un chiffre retombe pile sur une barre de mesure

  module_function

  def xml_escape(s)
    s.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')
  end

  def svg_text(x, y, text, size:, anchor: 'middle', weight: nil)
    return '' if text.nil? || text.to_s.empty?

    w = weight ? %( font-weight="#{weight}") : ''
    %(<text x="#{x.round(2)}" y="#{y.round(2)}" font-family="Helvetica, Arial, sans-serif" font-size="#{size}" text-anchor="#{anchor}"#{w}>#{xml_escape(text)}</text>)
  end

  def svg_line(x1, y1, x2, y2, width: 0.6)
    %(<line x1="#{x1.round(2)}" y1="#{y1.round(2)}" x2="#{x2.round(2)}" y2="#{y2.round(2)}" stroke="black" stroke-width="#{width}"/>)
  end

  # Chiffre corde:case posé SUR une ligne de corde : un rectangle blanc opaque
  # sous le texte masque localement la ligne (sinon la ligne barre le chiffre,
  # Phil 2026-08-28 : "moche") — largeur approximative selon le nombre de
  # chiffres (jusqu'à 2, cases > 99 improbables sur une tablature).
  def number_glyph(x, y, text)
    w = (text.length * NUMBER_SIZE * 0.75) + 1.0
    h = NUMBER_SIZE + 1.0
    rect = %(<rect x="#{(x - w / 2).round(2)}" y="#{(y - h * 0.75).round(2)}" width="#{w.round(2)}" height="#{h.round(2)}" fill="white"/>)
    rect + svg_text(x, y + NUMBER_SIZE * 0.35, text, size: NUMBER_SIZE)
  end

  def string_y(corde, top_y)
    top_y + (corde - 1) * LINE_SPACING
  end

  # Nombre de crochets de jambage pour un dénominateur donné (4->0, 8->1, 16->2...).
  def flag_count(denom)
    return 0 if denom <= 4

    Math.log2(denom / 4.0).round
  end

  # Dessine UN événement (note/accord/silence) à l'abscisse `x`, dans le système
  # dont la ligne du haut est à `top_y`. `parts` : tableau de fragments SVG en sortie.
  # Le jambage (stem) est décalé à DROITE du chiffre (jamais dessus, sinon
  # collision visible avec un chiffre à 2 caractères) ; le doigté (main droite/
  # gauche) est toujours ancré sous la DERNIÈRE ligne de la portée (`bottom_y`),
  # jamais sous la corde de CET événement — sinon un doigté sur une corde haute
  # atterrit EN PLEIN MILIEU de la portée, par-dessus d'autres chiffres.
  def draw_event(parts, ev, x, top_y, bottom_y)
    return if ev.kind == :rest || ev.kind == :skip

    ev.notes.each do |n|
      parts << number_glyph(x, string_y(n[:corde], top_y), n[:case].to_s)
    end

    topmost = ev.notes.map { |n| n[:corde] }.min
    n_flags = flag_count(ev.denom)
    if n_flags.positive?
      stem_x = x + NUMBER_SIZE * 1.3
      stem_bottom = string_y(topmost, top_y) - LINE_SPACING * 0.5
      stem_top = stem_bottom - STEM_HEIGHT
      parts << svg_line(stem_x, stem_bottom, stem_x, stem_top)
      n_flags.times do |i|
        fy = stem_top + i * FLAG_GAP
        parts << svg_line(stem_x, fy, stem_x + FLAG_LEN, fy + FLAG_LEN, width: 1.1)
      end
    end

    finger_y = bottom_y + LINE_SPACING * 0.5 + FINGER_SIZE
    if ev.rh
      parts << svg_text(x, finger_y, ev.rh, size: FINGER_SIZE)
      finger_y += FINGER_SIZE + ROW_GAP
    end
    parts << svg_text(x, finger_y, ev.lh, size: FINGER_SIZE) if ev.lh
  end

  # Rend le contenu `.tab` (frontmatter + corps) en UN SVG multi-système.
  # `available_width_pt` : largeur de colonne dispo (systèmes découpés pour y
  # tenir) — passer une très grande valeur pour un rendu en système UNIQUE
  # (aperçu CLI/assistant, comportement historique).
  # `measures_per_line` : impose le nombre de mesures par système (layout
  # `tabla_measures_per_page`), prime sur le calcul automatique.
  # `system_spacing` : écart vertical (pt) entre deux systèmes.
  # Renvoie {svg:, width_pt:, height_pt:}.
  def render_tab_svg(content, available_width_pt: nil, measures_per_line: nil, system_spacing: 16.0)
    meta, body = parse_frontmatter(content)
    tokens = tokenize(body)
    time = meta['metrique'] || meta['time'] || '4/4'
    measures, target_beats = parse_measures(tokens, time, chord_names: !!meta['chord'])
    raise ParseError, 'tablature vide' if measures.empty?

    measure_width = target_beats * BEAT_WIDTH
    mpl = measures_per_line || [((available_width_pt - TIME_SIG_W) / measure_width).floor, 1].max
    mpl = [mpl, 1].max
    systems = measures.each_slice(mpl).to_a

    top_margin = STEM_HEIGHT + CHORD_NAME_SIZE + ROW_GAP * 2 + (meta['capo'] ? CHORD_NAME_SIZE + ROW_GAP : 0)
    bottom_margin = FINGER_SIZE * 2 + ROW_GAP * 2
    system_h = top_margin + STAFF_HEIGHT + bottom_margin
    width_pt = TIME_SIG_W + mpl * measure_width
    height_pt = systems.size * system_h + [systems.size - 1, 0].max * system_spacing

    parts = []

    systems.each_with_index do |system_measures, si|
      top_y = si * (system_h + system_spacing) + top_margin
      staff_bottom = top_y + STAFF_HEIGHT
      chord_name_baseline = top_y - STEM_HEIGHT - ROW_GAP
      capo_baseline = chord_name_baseline - CHORD_NAME_SIZE - ROW_GAP
      parts << capo_markup(meta['capo'], TIME_SIG_W, capo_baseline) if si.zero? && meta['capo']
      (1..TAB_LINES).each { |c| parts << svg_line(0, string_y(c, top_y), width_pt, string_y(c, top_y)) }
      parts << time_signature_markup(time, TIME_SIG_W * 0.5, top_y + STAFF_HEIGHT * 0.5) if si.zero?
      parts << svg_line(TIME_SIG_W, top_y, TIME_SIG_W, staff_bottom)

      x = TIME_SIG_W
      system_measures.each do |measure|
        acc = 0.0
        # `NOTE_INSET` : marge à l'intérieur de la mesure — sans ça le 1er/dernier
        # événement retombe PILE sur la barre de mesure, chiffre et trait confondus.
        content_width = measure_width - 2 * NOTE_INSET
        measure[:events].each do |ev|
          ex = x + NOTE_INSET + (acc / target_beats) * content_width
          draw_event(parts, ev, ex, top_y, staff_bottom)
          acc += ev.beats
        end
        parts << svg_text(x + measure_width * 0.5, chord_name_baseline, measure[:label], size: CHORD_NAME_SIZE, weight: 'bold') if measure[:label]
        x += measure_width
        parts << svg_line(x, top_y, x, staff_bottom)
      end
    end

    svg = <<~SVG
      <svg xmlns="http://www.w3.org/2000/svg" width="#{width_pt.round(2)}pt" height="#{height_pt.round(2)}pt" viewBox="0 0 #{width_pt.round(2)} #{height_pt.round(2)}">
      #{parts.join("\n")}
      </svg>
    SVG

    { svg: svg, width_pt: width_pt, height_pt: height_pt }
  end

  def ordinal_fr(n)
    n.to_i == 1 ? '1er' : "#{n}e"
  end

  def capo_markup(capo, x, y)
    svg_text(x, y, "Capo : #{ordinal_fr(capo)}", size: CHORD_NAME_SIZE, anchor: 'start')
  end

  def time_signature_markup(time, x, y)
    num, den = time.split('/')
    return '' unless den

    svg_text(x, y - 2, num, size: 9, weight: 'bold') + svg_text(x, y + 9, den, size: 9, weight: 'bold')
  end
end
