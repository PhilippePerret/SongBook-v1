# frozen_string_literal: true

# tools/tablator/renderer.rb : rendu SVG géométrique direct (pas de moteur de
# notation externe) d'une tablature déjà parsée en mesures
# (`Tablator.parse_measures`, voir `parser.rb`). Aucune logique de lecture/
# syntaxe ici — séparé pour limiter les collisions d'édition entre "comment on
# LIT une tablature" et "comment on la DESSINE" (Phil, 2026-08-28).
#
# `render_tab_svg` renvoie UN SVG PAR SYSTÈME (Phil, 2026-08-28 : "chaque
# système doit être un élément de pagination indépendant" — 2 systèmes peuvent
# tenir sur une page, le 3e passer sur la suivante). Chaque système est donc
# géométriquement AUTONOME (largeur = exactement ses mesures, pas de marge
# fantôme) ; l'empilement/espacement entre systèmes n'est plus géré ici mais
# par la pagination normale de l'app (`Layout.paginate`, comme pour un couplet).

module Tablator
  TAB_LINES = 6
  # Écart entre deux lignes de corde (pt) — Phil, 2026-08-28 (redemandé, "les
  # lignes peuvent encore être rapprochées") : 8.0 → 6.0 → 5.0.
  LINE_SPACING = 5.0
  STAFF_HEIGHT = LINE_SPACING * (TAB_LINES - 1)
  NUMBER_SIZE = 6.5
  # Hampe (Phil, 2026-08-28 : "les hampes de croches sont ridiculement
  # petites") — assez haute pour porter 1-2 ligatures lisibles au-dessus, mais
  # sans gonfler la marge au-dessus de CHAQUE système (redescendue de 22 après
  # le passage à `stems_extra_height` — la marge réservée n'est plus gaspillée
  # même quand aucune note n'en a besoin, donc plus besoin de compenser large).
  STEM_HEIGHT = 19.0
  # Écart entre la ligne de corde et le PIED de la hampe (Phil, 2026-08-28 :
  # "les hampes sont trop près des notes" — remontées) — indépendant de
  # `LINE_SPACING` pour ne pas se réduire avec lui si la portée se resserre encore.
  STEM_GAP = 3.5
  FLAG_LEN = 4.5
  BEAM_GAP = 2.6            # écart vertical entre deux ligatures empilées (16e, 32e...)
  BEAM_WIDTH = 1.6
  CHORD_NAME_SIZE = 7.0
  ROW_GAP = 2.5
  FINGER_SIZE = 6.0
  TIME_SIG_W = 15.0         # marge gauche réservée à l'indicatif
  # Marge à droite du dernier trait de mesure (Phil, 2026-08-28 : "pas de barre
  # de fin de système") — un trait dessiné PILE sur le bord du SVG est parfois
  # rogné par le moteur de rendu PDF (vérifié : présent dans le SVG source,
  # absent une fois intégré) ; ce coussin le maintient visible.
  RIGHT_MARGIN = 2.0
  BEAT_WIDTH = 18.0         # largeur (pt) d'un temps (noire) — LE réglage taille/densité
  # Marge à l'intérieur de la mesure (Phil, 2026-08-28 : "les notes sont trop
  # collées à leur barre de gauche") — sans ça le 1er/dernier événement retombe
  # pile sur la barre de mesure, chiffre et trait confondus.
  NOTE_INSET = 10.0

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

  # Chiffre corde:case — fond TRANSPARENT (Phil, 2026-08-28 : un rectangle blanc
  # débordait sur la ligne de corde du DESSUS). La ligne de corde elle-même est
  # coupée localement à son emplacement (voir `line_with_gaps`) : plus besoin de
  # la masquer après coup.
  def number_glyph(x, y, text)
    svg_text(x, y + NUMBER_SIZE * 0.35, text, size: NUMBER_SIZE)
  end

  # Demi-largeur (+ un peu d'air) occupée par un chiffre à l'emplacement `x` —
  # sert à couper la ligne de corde localement (`line_with_gaps`), plus à
  # masquer un rectangle par-dessus.
  def number_half_width(text)
    (text.to_s.length * NUMBER_SIZE * 0.375) + 0.8
  end

  def string_y(corde, top_y)
    top_y + (corde - 1) * LINE_SPACING
  end

  # Ligne de corde COUPÉE aux emplacements occupés par un chiffre (Phil,
  # 2026-08-28 : fond transparent, jamais un rectangle par-dessus). `ranges` :
  # liste de [x_debut, x_fin] à exclure, pas forcément triée/fusionnée.
  def line_with_gaps(x0, x1, y, ranges)
    sorted = ranges.map { |a, b| [[a, x0].max, [b, x1].min] }.select { |a, b| b > a }.sort_by(&:first)
    parts = []
    cursor = x0
    sorted.each do |a, b|
      parts << svg_line(cursor, y, a, y) if a > cursor
      cursor = [cursor, b].max
    end
    parts << svg_line(cursor, y, x1, y) if x1 > cursor
    parts
  end

  # Nombre de ligatures/crochets pour un dénominateur donné (4->0, 8->1, 16->2...).
  def flag_count(denom)
    return 0 if denom <= 4

    Math.log2(denom / 4.0).round
  end

  def draw_numbers(parts, ev, x, top_y)
    return if ev.kind == :rest || ev.kind == :skip

    ev.notes.each { |n| parts << number_glyph(x, string_y(n[:corde], top_y), n[:case].to_s) }
  end

  def draw_fingering(parts, ev, x, bottom_y)
    return if ev.kind == :rest || ev.kind == :skip

    finger_y = bottom_y + LINE_SPACING * 0.5 + FINGER_SIZE
    if ev.rh
      parts << svg_text(x, finger_y, ev.rh, size: FINGER_SIZE)
      finger_y += FINGER_SIZE + ROW_GAP
    end
    parts << svg_text(x, finger_y, ev.lh, size: FINGER_SIZE) if ev.lh
  end

  # Dessine hampe(s) + ligature(s) pour UN groupe d'événements déjà décidé
  # "attaché ensemble" (voir `draw_stems`) — 1 seul élément : hampe simple
  # (+ crochets individuels si croche ou moins) ; plusieurs : hampe par note,
  # toutes jusqu'à une ligne de ligature COMMUNE (`beam_top`), qui porte
  # autant de barres empilées que nécessaire (ligatures niveau par niveau,
  # comme une gravure classique — un groupe mixte croches/doubles-croches
  # n'a qu'UNE ligature de niveau 2 sur la portion qui la partage, les autres
  # notes du groupe recevant un talon court).
  def draw_stem_group(parts, group, top_y)
    return if group.empty?

    stems = group.map do |g|
      ev = g[:ev]
      topmost_note = ev.notes.min_by { |n| n[:corde] }
      # Hampe EXACTEMENT sur l'abscisse du chiffre (Phil, 2026-08-28, redemandé :
      # "toujours désalignées" — un décalage, même proportionnel au chiffre, reste
      # visuellement détaché). Pas de risque de collision avec le chiffre lui-même :
      # la hampe reste toujours AU-DESSUS de la portée, le chiffre est SUR la ligne.
      { x: g[:x], bottom: string_y(topmost_note[:corde], top_y) - STEM_GAP, denom: ev.denom }
    end
    beam_top = stems.map { |s| s[:bottom] - STEM_HEIGHT }.min
    stems.each { |s| parts << svg_line(s[:x], s[:bottom], s[:x], beam_top) }

    if stems.size == 1
      flag_count(stems.first[:denom]).times do |i|
        y = beam_top + i * BEAM_GAP
        parts << svg_line(stems.first[:x], y, stems.first[:x] + FLAG_LEN, y + FLAG_LEN * 0.7, width: BEAM_WIDTH)
      end
      return
    end

    max_level = stems.map { |s| flag_count(s[:denom]) }.max
    (1..max_level).each do |level|
      i = 0
      while i < stems.size
        if flag_count(stems[i][:denom]) >= level
          j = i
          j += 1 while j + 1 < stems.size && flag_count(stems[j + 1][:denom]) >= level
          y = beam_top + (level - 1) * BEAM_GAP
          if j > i
            parts << svg_line(stems[i][:x], y, stems[j][:x], y, width: BEAM_WIDTH)
          else
            parts << svg_line(stems[i][:x], y, stems[i][:x] + FLAG_LEN, y + FLAG_LEN * 0.7, width: BEAM_WIDTH)
          end
          i = j + 1
        else
          i += 1
        end
      end
    end
  end

  # Regroupe les événements POSITIONNÉS (`{ev:, x:, beat_idx:}`) d'une mesure
  # en groupes "attachés par temps" (Phil, 2026-08-28) : notes consécutives
  # croche-ou-moins PARTAGEANT le même temps (`beat_idx`, partie entière de
  # l'accumulation de durée) — une noire/blanche, un silence, ou un changement
  # de temps rompt le groupe. Ronde (denom 1) : pas de hampe du tout.
  def draw_stems(parts, positioned, top_y)
    i = 0
    while i < positioned.size
      ev = positioned[i][:ev]
      if ev.kind != :notes || ev.denom <= 1
        i += 1
        next
      end
      if ev.denom < 8
        draw_stem_group(parts, [positioned[i]], top_y)
        i += 1
        next
      end
      j = i
      beat0 = positioned[i][:beat_idx]
      while j + 1 < positioned.size &&
            positioned[j + 1][:ev].kind == :notes &&
            positioned[j + 1][:ev].denom >= 8 &&
            positioned[j + 1][:beat_idx] == beat0
        j += 1
      end
      draw_stem_group(parts, positioned[i..j], top_y)
      i = j + 1
    end
  end

  # Un système, entièrement autonome (largeur = SES mesures uniquement — Phil,
  # 2026-08-28 : "les lignes doivent s'arrêter sur la dernière barre").
  # `show_time_sig`/`capo` : seul le 1er système d'une tablature les affiche
  # (voir `render_tab_svg`).
  # Hauteur de hampe RÉELLEMENT nécessaire pour ce système (Phil, 2026-08-28 :
  # "systèmes toujours trop écartés"/"titre trop loin" — plancher/plafond fixes
  # gaspillaient de la place même quand rien n'en avait besoin). 0 si aucune note
  # tenue (silence/ronde uniquement — cas rarissime, mais jamais négatif).
  def stems_extra_height(measures)
    any_stem = measures.any? { |m| m[:events].any? { |ev| ev.kind == :notes && ev.denom > 1 } }
    # Les ligatures de niveau 2+ s'empilent VERS la note (voir `draw_stem_group`,
    # `beam_top + (level-1)*BEAM_GAP`), jamais au-dessus du niveau 1 — la hauteur
    # maxi au-dessus de la portée reste `STEM_HEIGHT`, quel que soit le nombre de
    # ligatures.
    any_stem ? STEM_HEIGHT : 0
  end

  # Place pour le doigté (Phil, 2026-08-28, même remarque) : 0 si aucun événement
  # du système n'en porte, 1 rangée si un seul type (droite OU gauche) suffit,
  # 2 rangées seulement si un même événement cumule les deux.
  def fingering_extra_height(measures)
    any_rh_or_lh = false
    any_both = false
    measures.each do |m|
      m[:events].each do |ev|
        next unless ev.kind == :notes

        any_rh_or_lh ||= !!(ev.rh || ev.lh)
        any_both ||= !!(ev.rh && ev.lh)
      end
    end
    return 0 unless any_rh_or_lh

    any_both ? FINGER_SIZE * 2 + ROW_GAP : FINGER_SIZE + ROW_GAP
  end

  def render_system(measures, time, target_beats, meta, show_time_sig:)
    measure_width = target_beats * BEAT_WIDTH
    any_label = meta['chord'] || measures.any? { |m| m[:label] }
    top_margin = stems_extra_height(measures) + ROW_GAP +
      (any_label ? CHORD_NAME_SIZE + ROW_GAP : 0) +
      (show_time_sig && meta['capo'] ? CHORD_NAME_SIZE + ROW_GAP : 0)
    bottom_margin = fingering_extra_height(measures) + ROW_GAP
    top_y = top_margin
    staff_bottom = top_y + STAFF_HEIGHT
    content_width = TIME_SIG_W + measures.size * measure_width
    width_pt = content_width + RIGHT_MARGIN
    height_pt = top_margin + STAFF_HEIGHT + bottom_margin

    parts = []
    chord_name_baseline = top_y - stems_extra_height(measures) - ROW_GAP
    capo_baseline = chord_name_baseline - CHORD_NAME_SIZE - ROW_GAP
    parts << capo_markup(meta['capo'], TIME_SIG_W, capo_baseline) if show_time_sig && meta['capo']
    (1..TAB_LINES).each { |c| parts << svg_line(0, string_y(c, top_y), content_width, string_y(c, top_y)) }
    parts << time_signature_markup(time, TIME_SIG_W * 0.5, top_y + STAFF_HEIGHT * 0.5) if show_time_sig

    x = TIME_SIG_W
    measures.each do |measure|
      acc = 0.0
      content_width = measure_width - 2 * NOTE_INSET
      positioned = measure[:events].map do |ev|
        entry = { ev: ev, x: x + NOTE_INSET + (acc / target_beats) * content_width, beat_idx: acc.floor }
        acc += ev.beats
        entry
      end
      positioned.each { |e| draw_numbers(parts, e[:ev], e[:x], top_y) }
      draw_stems(parts, positioned, top_y)
      positioned.each { |e| draw_fingering(parts, e[:ev], e[:x], staff_bottom) }
      parts << svg_text(x + measure_width * 0.5, chord_name_baseline, measure[:label], size: CHORD_NAME_SIZE, weight: 'bold') if measure[:label]
      x += measure_width
      # Pas de barre en tout DÉBUT de système (Phil, 2026-08-28) — seulement
      # entre les mesures et à la toute fin.
      parts << svg_line(x, top_y, x, staff_bottom)
    end

    svg = <<~SVG
      <svg xmlns="http://www.w3.org/2000/svg" width="#{width_pt.round(2)}pt" height="#{height_pt.round(2)}pt" viewBox="0 0 #{width_pt.round(2)} #{height_pt.round(2)}">
      #{parts.join("\n")}
      </svg>
    SVG

    { svg: svg, width_pt: width_pt, height_pt: height_pt }
  end

  # Rend le contenu `.tab` (frontmatter + corps) en autant de SVG que de
  # systèmes (Phil, 2026-08-28 : pagination indépendante système par système —
  # voir l'en-tête du fichier). `available_width_pt` : largeur de colonne
  # dispo (systèmes découpés pour y tenir) — passer une très grande valeur
  # pour un rendu en système UNIQUE (aperçu CLI/assistant).
  # `measures_per_line` : impose le nombre de mesures par système (layout
  # `tabla_measures_per_page`), prime sur le calcul automatique.
  # Renvoie [{svg:, width_pt:, height_pt:}, ...] (1 par système).
  def render_tab_svg(content, available_width_pt: nil, measures_per_line: nil)
    meta, body = parse_frontmatter(content)
    tokens = tokenize(body)
    time = meta['metrique'] || meta['time'] || '4/4'
    measures, target_beats = parse_measures(tokens, time, chord_names: !!meta['chord'])
    raise ParseError, 'tablature vide' if measures.empty?

    measure_width = target_beats * BEAT_WIDTH
    mpl = measures_per_line || [((available_width_pt - TIME_SIG_W) / measure_width).floor, 1].max
    mpl = [mpl, 1].max
    systems = measures.each_slice(mpl).to_a

    systems.each_with_index.map do |system_measures, si|
      render_system(system_measures, time, target_beats, meta, show_time_sig: si.zero?)
    end
  end

  def ordinal_fr(n)
    n.to_i == 1 ? '1er' : "#{n}e"
  end

  def capo_markup(capo, x, y)
    svg_text(x, y, "Capo : #{ordinal_fr(capo)}", size: CHORD_NAME_SIZE, anchor: 'start')
  end

  # Chiffres empilés proches (Phil, 2026-08-28 : "trop écartés") — écart réduit
  # au minimum lisible entre les deux lignes de base.
  def time_signature_markup(time, x, y)
    num, den = time.split('/')
    return '' unless den

    svg_text(x, y - 1, num, size: 9, weight: 'bold') + svg_text(x, y + 7, den, size: 9, weight: 'bold')
  end
end
