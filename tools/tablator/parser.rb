# frozen_string_literal: true

# tools/tablator/parser.rb : lecture de la syntaxe tablature simplifiée
# (frontmatter, tokens, accords) et regroupement en mesures RÉELLES — aucun
# dessin ici (voir `renderer.rb`). Séparé de `renderer.rb` pour limiter les
# collisions d'édition entre "comment on LIT une tablature" et "comment on la
# DESSINE" (Phil, 2026-08-28).

require 'yaml'

module Tablator
  # Cordes numérotées 1 (aiguë) .. 6 (grave), hauteur à vide en numéro MIDI —
  # seulement utile pour deviner le nom d'un accord (`chord_label`), pas pour
  # le dessin (qui travaille directement en corde/case).
  OPEN_STRING_MIDI = {
    1 => 64, # mi4
    2 => 59, # si3
    3 => 55, # sol3
    4 => 50, # ré3
    5 => 45, # la2
    6 => 40  # mi2
  }.freeze

  NOTE_LETTERS = %w[C C# D D# E F F# G G# A A# B].freeze

  # Formules d'accords (intervalles en demi-tons depuis la fondamentale).
  CHORD_FORMULAS = {
    '' => [0, 4, 7],      # majeur
    'm' => [0, 3, 7],      # mineur
    '7' => [0, 4, 7, 10],
    'maj7' => [0, 4, 7, 11],
    'm7' => [0, 3, 7, 10],
    'dim' => [0, 3, 6],
    'aug' => [0, 4, 8],
    'sus2' => [0, 2, 7],
    'sus4' => [0, 5, 7]
  }.freeze

  # Durée restreinte à `[\d.]+` (pas `\S+`) : doit s'arrêter AVANT un éventuel
  # `-<doigté>` (Phil, 2026-08-26). Groupes 4/5 : doigté main droite (p/i/m/a/c),
  # doigté main gauche (chiffre) — ex. "60/4-p2" (corde6 case0 noire, pouce + 2e doigt).
  CORDE_CASE_RE = %r{\A([1-6])(\d+)(?:/([\d.]+))?(?:-([pimac])?(\d)?)?\z}.freeze
  CHORD_RE = %r{\A(\w+)?<([^>]+)>(?:/(\S+))?\z}.freeze
  # `r<durée>` (silence visible) / `s<durée>` (silence invisible, "skip" — compte pour
  # le placement des barres sans être marqué, typiquement une levée).
  REST_RE = /\A([rs])([\d.]+)\z/.freeze
  # Barres de mesure (les 6 formes — Phil, 2026-08-26 : simple, fin de morceau, double
  # (fin de partie), reprises) — un seul style de tracé pour l'instant (pas de
  # distinction visuelle simple/double/reprise, à affiner si besoin).
  BAR_RE = /\A(\|\.|\|\||:\|:|:\||\|:|\|)\z/.freeze
  # Nom d'accord explicite, ex: [Am7], qui prime sur le calcul auto.
  EXPLICIT_CHORD_RE = /\A\[(.+)\]\z/.freeze

  class ParseError < StandardError; end

  module_function

  def corde_case_midi(corde, case_num)
    base = OPEN_STRING_MIDI.fetch(corde) { raise ParseError, "corde inconnue : #{corde}" }
    base + case_num
  end

  # Déduit un nom d'accord (ex: "Am", "C") depuis un ensemble de classes de
  # hauteurs (0..11) en essayant chaque note comme fondamentale possible.
  # `basse` (classe de hauteur de la note la plus grave) sert à départager
  # plusieurs correspondances.
  def chord_label(pitch_classes, basse)
    pcs = pitch_classes.uniq
    candidats = []
    pcs.each do |racine|
      intervalles = pcs.map { |p| (p - racine) % 12 }.sort
      CHORD_FORMULAS.each { |suffixe, formule| candidats << [racine, suffixe] if intervalles == formule }
    end
    return nil if candidats.empty?

    racine, suffixe = candidats.find { |r, _| r == basse } || candidats.first
    "#{NOTE_LETTERS[racine]}#{suffixe}"
  end

  # Classes de hauteurs (0..11) d'un token accord <c:f c:f ...>, ou nil si ce
  # n'en est pas un.
  def chord_midis(token)
    m = CHORD_RE.match(token) or return nil
    m[2].split(/\s+/).map do |pair|
      cm = CORDE_CASE_RE.match(pair) or raise ParseError, "note d'accord illisible : #{pair}"
      corde_case_midi(cm[1].to_i, cm[2].to_i)
    end
  end

  # Dénominateur de durée associé à chaque plus petite division saisissable
  # (frontmatter `unit:`, voir `TablatorAssistant::DURATIONS` — même table) —
  # référence gardée pour l'assistant interactif, pas utilisée par le rendu
  # (qui lit le dénominateur explicite de chaque token).
  UNIT_DENOMINATOR = { 'noire' => 4, 'croche' => 8, 'double-croche' => 16, 'triple-croche' => 32 }.freeze

  def strip_comments(body)
    body.each_line.map { |line| line.sub(/#(?:\s.*)?\z/, '') }.join
  end

  def tokenize(body)
    strip_comments(body).scan(/\w*<[^>]*>\S*|\S+/)
  end

  def parse_frontmatter(content)
    return [{}, content] unless content.start_with?('---')

    _, front, body = content.split(/^---\s*$/m, 3)
    [YAML.safe_load(front) || {}, body.to_s]
  end

  # Durée d'un `[\d.]+` en temps (noire = 1) — N = 4/N temps, chaque point
  # ajoute la moitié de l'incrément précédent (formule standard : 2 - 0.5**dots).
  def duration_str_to_beats(dur_str)
    base = dur_str[/\A\d+/].to_i
    return 1.0 if base.zero?

    dots = dur_str.count('.')
    (4.0 / base) * (2 - (0.5**dots))
  end

  # "N/D" affichable pour un total de temps (noire = 1) donné — GARDE le
  # dénominateur `base_den` de la métrique en cours (une mesure analysée à la
  # lueur de la précédente, sauf indication contraire : Phil, 2026-08-29,
  # "si on est en /4, le temps est une noire" — jamais sauter à une autre
  # valeur de note, ex. "1/2", juste parce que ça tombe aussi juste). Affine
  # seulement (double le dénominateur) si `base_den` ne rend pas N entier.
  def beats_to_time_str(beats, base_den = 4)
    den = base_den
    32.times do
      num = beats * den / 4.0
      return "#{num.round}/#{den}" if (num - num.round).abs < 0.001

      den *= 2
    end
    "#{beats.round}/#{base_den}"
  end

  # Un "événement" de tablature : une note, un accord, ou un silence — jamais
  # une barre (consommée à part). `notes` : liste de {corde:, case:} (1 seul
  # élément pour une note simple, plusieurs pour un accord).
  Event = Struct.new(:kind, :notes, :arpeggio, :denom, :beats, :rh, :lh, keyword_init: true)

  def parse_event(token, last_duration)
    if (m = REST_RE.match(token))
      dur = m[2]
      Event.new(kind: (m[1] == 'r' ? :rest : :skip), notes: [], denom: dur[/\A\d+/].to_i, beats: duration_str_to_beats(dur))
    elsif (m = CHORD_RE.match(token))
      prefix, inner, duree = m.captures
      dur = duree || last_duration
      notes = inner.split(/\s+/).map do |pair|
        cm = CORDE_CASE_RE.match(pair) or raise ParseError, "note d'accord illisible : #{pair}"
        { corde: cm[1].to_i, case: cm[2].to_i }
      end
      Event.new(kind: :notes, notes: notes, arpeggio: prefix == 'Arp', denom: dur[/\A\d+/].to_i, beats: duration_str_to_beats(dur))
    elsif (m = CORDE_CASE_RE.match(token))
      corde, kase, duree, rh, lh = m.captures
      dur = duree || last_duration
      Event.new(kind: :notes, notes: [{ corde: corde.to_i, case: kase.to_i }], denom: dur[/\A\d+/].to_i, beats: duration_str_to_beats(dur), rh: rh, lh: lh)
    else
      raise ParseError, "token illisible : #{token}"
    end
  end

  # Regroupe les tokens en mesures RÉELLES (Phil, 2026-08-27) : accumulation des
  # durées de chaque événement contre la métrique (`time`, "N/D"), PAS le comptage
  # des barres explicites du code (souvent absentes/rares). Une barre explicite
  # force quand même une coupure (mesure incomplète volontaire, levée...).
  # Renvoie [mesures, target_beats] — chaque mesure = {events: [Event...], label:}.
  def parse_measures(tokens, time, chord_names:)
    num, den = time.to_s =~ %r{\A(\d+)/(\d+)\z} ? [$1.to_i, $2.to_i] : [4, 4]
    target = num * (4.0 / den)

    measures = []
    events = []
    label = nil
    acc = 0.0
    last_duration = '4'

    close = lambda do
      next if events.empty?

      measures << { events: events, label: label, beats: acc }
      events = []
      label = nil
      acc = 0.0
    end

    tokens.each do |t|
      if BAR_RE.match?(t)
        close.call
        next
      end
      if (m = EXPLICIT_CHORD_RE.match(t))
        label = m[1]
        next
      end

      ev = parse_event(t, last_duration)
      last_duration = ev.denom.to_s
      if ev.kind == :notes && ev.notes.size > 1 && chord_names && !label
        midis = ev.notes.map { |n| corde_case_midi(n[:corde], n[:case]) }
        label = chord_label(midis.map { |m| m % 12 }, midis.min % 12)
      end
      events << ev
      acc += ev.beats
      close.call if acc >= target - 0.001
    end
    close.call
    [measures, target]
  end

  # Analyse UNE source `.tab` (frontmatter + corps) en mesures — chacune taguée
  # de SA PROPRE métrique/unité (`:time`/`:target_beats`/`:unit_denom`/`:slots`,
  # Phil, 2026-08-28 : "changement de métrique d'un segment à l'autre" —
  # "amorce" en 3/4, la suite en 4/4). Sert à fusionner plusieurs sources SANS
  # leur imposer la métrique du premier fichier (voir `PageBuilder.tab_source_content`,
  # qui ne fusionne plus le TEXTE mais transmet les sources séparément).
  # Renvoie [mesures, meta] — `meta` de CETTE source (capo/chord/titre...).
  def parse_source_measures(content)
    meta, body = parse_frontmatter(content)
    tokens = tokenize(body)
    time = meta['metrique'] || meta['time'] || '4/4'
    unit_denom = UNIT_DENOMINATOR.fetch(meta['unit'], 8)
    measures, target_beats = parse_measures(tokens, time, chord_names: !!meta['chord'])
    measures.each do |m|
      m[:time] = time
      m[:target_beats] = target_beats
      m[:unit_denom] = unit_denom
      # Largeur au prorata des temps RÉELLEMENT présents dans la mesure (pas la
      # métrique cible) — une mesure coupée court (barre explicite avant la fin,
      # levée...) doit occuper moins de place qu'une mesure complète.
      m[:slots] = m[:beats] * unit_denom / 4.0
      # Métrique EFFECTIVEMENT affichée pour cette mesure (Phil, 2026-08-29) :
      # celle du frontmatter, SAUF si son nombre de temps réel diffère (mesure
      # incomplète/irrégulière) — affiche alors la métrique réelle ("2/4"), ce
      # qui déclenche aussi son propre changement d'indicatif (voir `render_tab_svg`).
      time_den = time.to_s[%r{/(\d+)\z}, 1].to_i
      time_den = 4 if time_den.zero?
      m[:display_time] = (m[:beats] - target_beats).abs > 0.001 ? beats_to_time_str(m[:beats], time_den) : time
    end
    [measures, meta]
  end
end
