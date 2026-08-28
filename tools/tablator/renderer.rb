# frozen_string_literal: true

# tools/tablator/renderer.rb : rendu SVG géométrique direct (pas de moteur de
# notation externe) d'une tablature déjà parsée en mesures
# (`Tablator.parse_measures`, voir `parser.rb`). Aucune logique de lecture/
# syntaxe ici — séparé pour limiter les collisions d'édition entre "comment on
# LIT une tablature" et "comment on la DESSINE" (Phil, 2026-08-28).
#
# Toutes les tailles/écarts viennent du preset ACTIF (`Tablator.param`, voir
# `presets.rb`) — jamais de constante en dur ici (Phil, 2026-08-28 : "garder
# cette config enregistrée en dur quelque part", pour pouvoir en essayer
# d'autres, ex. "mini-tablatures", sans toucher au code).
#
# `render_tab_svg` renvoie UN SVG PAR SYSTÈME (Phil, 2026-08-28 : "chaque
# système doit être un élément de pagination indépendant" — 2 systèmes peuvent
# tenir sur une page, le 3e passer sur la suivante). Chaque système est donc
# géométriquement AUTONOME (largeur = exactement ses mesures, pas de marge
# fantôme) ; l'empilement/espacement entre systèmes n'est plus géré ici mais
# par la pagination normale de l'app (`Layout.paginate`, comme pour un couplet).

module Tablator
  TAB_LINES = 6 # nombre de cordes — pas un réglage de preset, une guitare a 6 cordes.

  module_function

  def staff_height
    param(:line_spacing) * (TAB_LINES - 1)
  end

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
    svg_text(x, y + param(:number_size) * 0.35, text, size: param(:number_size))
  end

  # Demi-largeur (+ un peu d'air) occupée par un chiffre à l'emplacement `x` —
  # sert à couper la ligne de corde localement (`line_with_gaps`), plus à
  # masquer un rectangle par-dessus.
  def number_half_width(text)
    (text.to_s.length * param(:number_size) * 0.375) + 0.8
  end

  def string_y(corde, top_y)
    top_y + (corde - 1) * param(:line_spacing)
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

    finger_size = param(:finger_size)
    finger_y = bottom_y + param(:line_spacing) * 0.5 + finger_size
    if ev.rh
      parts << svg_text(x, finger_y, ev.rh, size: finger_size)
      finger_y += finger_size + param(:row_gap)
    end
    parts << svg_text(x, finger_y, ev.lh, size: finger_size) if ev.lh
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

    stem_gap = param(:stem_gap)
    stem_height = param(:stem_height)
    beam_gap = param(:beam_gap)
    flag_len = param(:flag_len)
    beam_width = param(:beam_width)

    stems = group.map do |g|
      ev = g[:ev]
      topmost_note = ev.notes.min_by { |n| n[:corde] }
      # Hampe EXACTEMENT sur l'abscisse du chiffre (Phil, 2026-08-28, redemandé :
      # "toujours désalignées" — un décalage, même proportionnel au chiffre, reste
      # visuellement détaché). Pas de risque de collision avec le chiffre lui-même :
      # la hampe reste toujours AU-DESSUS de la portée, le chiffre est SUR la ligne.
      { x: g[:x], bottom: string_y(topmost_note[:corde], top_y) - stem_gap, denom: ev.denom }
    end
    beam_top = stems.map { |s| s[:bottom] - stem_height }.min
    stems.each { |s| parts << svg_line(s[:x], s[:bottom], s[:x], beam_top) }

    if stems.size == 1
      flag_count(stems.first[:denom]).times do |i|
        y = beam_top + i * beam_gap
        parts << svg_line(stems.first[:x], y, stems.first[:x] + flag_len, y + flag_len * 0.7, width: beam_width)
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
          y = beam_top + (level - 1) * beam_gap
          if j > i
            parts << svg_line(stems[i][:x], y, stems[j][:x], y, width: beam_width)
          else
            parts << svg_line(stems[i][:x], y, stems[i][:x] + flag_len, y + flag_len * 0.7, width: beam_width)
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

  # Hauteur de hampe RÉELLEMENT nécessaire pour ce système (Phil, 2026-08-28 :
  # "systèmes toujours trop écartés"/"titre trop loin" — plancher/plafond fixes
  # gaspillaient de la place même quand rien n'en avait besoin). 0 si aucune note
  # tenue (silence/ronde uniquement — cas rarissime, mais jamais négatif).
  def stems_extra_height(measures)
    any_stem = measures.any? { |m| m[:events].any? { |ev| ev.kind == :notes && ev.denom > 1 } }
    # Les ligatures de niveau 2+ s'empilent VERS la note (voir `draw_stem_group`,
    # `beam_top + (level-1)*beam_gap`), jamais au-dessus du niveau 1 — la hauteur
    # maxi au-dessus de la portée reste `stem_height`, quel que soit le nombre de
    # ligatures.
    any_stem ? param(:stem_height) : 0
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

    finger_size = param(:finger_size)
    any_both ? finger_size * 2 + param(:row_gap) : finger_size + param(:row_gap)
  end

  # Nombre de PLUS PETITE DURÉE (`unit:` du frontmatter, défaut croche —
  # `Tablator::UNIT_DENOMINATOR`) que contient une mesure de métrique
  # `target_beats` — Phil, 2026-08-28 : "il faut chercher et définir les
  # paramètres sur lesquels on joue" — c'est l'unité de compte pour la largeur
  # (`duration_units_per_system`, `slot_width`), pas la mesure elle-même (deux
  # mesures de densité différente n'ont pas le même poids visuel).
  def measure_slots(target_beats, unit_denom)
    target_beats * unit_denom / 4.0
  end

  # `slot_width` : PAS un réglage user (voir `presets.rb`) — calculé par
  # `render_tab_svg` pour que `measures_per_system` tienne dans la largeur de
  # colonne réelle, jamais en dessous de `min_slot_width` (lisibilité).
  def render_system(measures, time, target_beats, meta, slot_width:, show_time_sig:)
    note_inset = param(:note_inset)
    time_sig_w = param(:time_sig_w)
    chord_name_size = param(:chord_name_size)
    row_gap = param(:row_gap)
    sh = staff_height

    unit_denom = UNIT_DENOMINATOR.fetch(meta['unit'], 8)
    slots = measure_slots(target_beats, unit_denom)
    # Position de départ FIXE (`note_inset`, contre la barre gauche, "la
    # position actuelle est bonne"), puis chaque événement placé au slot
    # correspondant à sa position cumulée dans la PLUS PETITE DURÉE — remplace
    # l'ancien double-retrait (marge des DEUX côtés, "trop d'espace à la fin
    # de la mesure").
    measure_width = note_inset + slots * slot_width
    any_label = meta['chord'] || measures.any? { |m| m[:label] }
    top_margin = stems_extra_height(measures) + row_gap +
      (any_label ? chord_name_size + row_gap : 0) +
      (show_time_sig && meta['capo'] ? chord_name_size + row_gap : 0)
    bottom_margin = fingering_extra_height(measures) + row_gap
    top_y = top_margin
    staff_bottom = top_y + sh
    total_content_w = time_sig_w + measures.size * measure_width
    width_pt = total_content_w + param(:right_margin)
    height_pt = top_margin + sh + bottom_margin

    # 1re passe : position de chaque événement + occupation de chaque ligne de
    # corde (pour la couper localement, `line_with_gaps` — Phil, 2026-08-28,
    # "le fond des chiffres doit être transparent", pas un rectangle par-dessus).
    x = time_sig_w
    measure_positions = measures.map do |measure|
      acc = 0.0
      positioned = measure[:events].map do |ev|
        entry = { ev: ev, x: x + note_inset + acc * (unit_denom / 4.0) * slot_width, beat_idx: acc.floor }
        acc += ev.beats
        entry
      end
      mp = { label: measure[:label], mid_x: x + measure_width * 0.5, events: positioned }
      x += measure_width
      mp
    end

    occupancy = Hash.new { |h, k| h[k] = [] }
    measure_positions.each do |mp|
      mp[:events].each do |e|
        next unless e[:ev].kind == :notes

        e[:ev].notes.each do |n|
          half = number_half_width(n[:case])
          occupancy[n[:corde]] << [e[:x] - half, e[:x] + half]
        end
      end
    end

    parts = []
    chord_name_baseline = top_y - stems_extra_height(measures) - row_gap
    capo_baseline = chord_name_baseline - chord_name_size - row_gap
    parts << capo_markup(meta['capo'], time_sig_w, capo_baseline) if show_time_sig && meta['capo']
    (1..TAB_LINES).each do |c|
      y = string_y(c, top_y)
      parts.concat(line_with_gaps(0, total_content_w, y, occupancy[c]))
    end
    parts << time_signature_markup(time, time_sig_w * 0.5, top_y + sh * 0.5) if show_time_sig

    measure_positions.each_with_index do |mp, i|
      mp[:events].each { |e| draw_numbers(parts, e[:ev], e[:x], top_y) }
      draw_stems(parts, mp[:events], top_y)
      mp[:events].each { |e| draw_fingering(parts, e[:ev], e[:x], staff_bottom) }
      parts << svg_text(mp[:mid_x], chord_name_baseline, mp[:label], size: chord_name_size, weight: 'bold') if mp[:label]
      # Pas de barre en tout DÉBUT de système (Phil, 2026-08-28) — seulement
      # entre les mesures et à la toute fin.
      bar_x = time_sig_w + (i + 1) * measure_width
      parts << svg_line(bar_x, top_y, bar_x, staff_bottom)
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
  # voir l'en-tête du fichier).
  #
  # `slot_width` (largeur, en pt, d'une plus petite durée) N'EST PAS un
  # réglage — CALCULÉ ici pour que `measures_per_system` (ou
  # `duration_units_per_system`, preset actif, voir `presets.rb`) tienne
  # EXACTEMENT dans `available_width_pt` (largeur de colonne réelle). Si ça
  # ne tiendrait pas lisiblement (`min_slot_width`), le nombre de mesures
  # visé est réduit tout seul (jamais un rendu illisible) — SAUF si
  # `measures_per_line` est donné explicitement (override `layout`
  # `tabla_measures_per_page` : décision assumée de l'user, jamais réduite
  # dans son dos). Sans `available_width_pt` connue (aperçu CLI/assistant) :
  # `slot_width` retombe sur son plancher de lisibilité.
  # Renvoie [{svg:, width_pt:, height_pt:}, ...] (1 par système).
  def render_tab_svg(content, available_width_pt: nil, measures_per_line: nil)
    meta, body = parse_frontmatter(content)
    tokens = tokenize(body)
    time = meta['metrique'] || meta['time'] || '4/4'
    measures, target_beats = parse_measures(tokens, time, chord_names: !!meta['chord'])
    raise ParseError, 'tablature vide' if measures.empty?

    unit_denom = UNIT_DENOMINATOR.fetch(meta['unit'], 8)
    slots = measure_slots(target_beats, unit_denom)
    note_inset = param(:note_inset)
    time_sig_w = param(:time_sig_w)
    min_slot_width = param(:min_slot_width)

    preset = PRESETS.fetch(active_preset)
    target_mpl = measures_per_line ||
      preset[:measures_per_system] ||
      (preset[:duration_units_per_system] && [(preset[:duration_units_per_system] / slots).floor, 1].max) || 1
    mpl = [target_mpl, 1].max

    if available_width_pt
      unless measures_per_line # jamais réduire un override explicite (layout) dans son dos
        mpl -= 1 while mpl > 1 && (available_width_pt - time_sig_w - mpl * note_inset) / (mpl * slots) < min_slot_width
      end
      slot_width = [(available_width_pt - time_sig_w - mpl * note_inset) / (mpl * slots), min_slot_width].max
    else
      slot_width = min_slot_width
    end

    systems = measures.each_slice(mpl).to_a

    systems.each_with_index.map do |system_measures, si|
      render_system(system_measures, time, target_beats, meta, slot_width: slot_width, show_time_sig: si.zero?)
    end
  end

  def ordinal_fr(n)
    n.to_i == 1 ? '1er' : "#{n}e"
  end

  def capo_markup(capo, x, y)
    svg_text(x, y, "Capo : #{ordinal_fr(capo)}", size: param(:chord_name_size), anchor: 'start')
  end

  # Chiffres empilés proches (Phil, 2026-08-28 : "trop écartés") — écart réduit
  # au minimum lisible entre les deux lignes de base.
  def time_signature_markup(time, x, y)
    num, den = time.split('/')
    return '' unless den

    svg_text(x, y - 1, num, size: 9, weight: 'bold') + svg_text(x, y + 7, den, size: 9, weight: 'bold')
  end
end
