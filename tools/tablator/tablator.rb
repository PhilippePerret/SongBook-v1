#!/usr/bin/env ruby
# frozen_string_literal: true

# tablator : traduit une tablature écrite en syntaxe simplifiée
# (cordecase, ou notes classiques avec -n) en image SVG, via LilyPond.
#
# Format d'entrée (corde/case, par défaut) :
#   <corde><case>[/<durée>]        note simple, ex: 50/4. (corde 5, case 0)
#   [Arp]<cf cf ...>[/<durée>]     accord, ex: Arp<42 32 21 10>/8
#   |                               barre de mesure, passée telle quelle
# Numérotation des cordes : 1 = corde aiguë (mi aigu) ... 6 = corde grave (mi grave).
# Le premier chiffre (1-6) est toujours la corde, le reste la case, ex: 112 = corde 1 case 12.
#
# Fichier d'entrée : frontmatter YAML optionnel entre "---", puis le corps.
#   ---
#   title: ...
#   metrique: 6/8
#   ---
#   50/4. Arp<42 32 21 10>/8 21 32 |

require 'optparse'
require 'yaml'
require 'json'
require 'tmpdir'
require 'fileutils'

module Tablator
  LILYPOND_VERSION = '2.20.0'

  # Cordes numérotées 1 (aiguë) .. 6 (grave), hauteur à vide en numéro MIDI.
  OPEN_STRING_MIDI = {
    1 => 64, # mi4
    2 => 59, # si3
    3 => 55, # sol3
    4 => 50, # ré3
    5 => 45, # la2
    6 => 40  # mi2
  }.freeze

  NOTE_NAMES = %w[c cis d dis e f fis g gis a ais b].freeze
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

  # Reconnaît un nom de note classique LilyPond en tête de token (c, d, e, f, g, a, b,
  # suivi d'altérations et d'octaves) pour le mode --notes.
  NOTE_TOKEN_RE = /\A([a-g])(is|es)?([',]*)(\d+\.*)?(\\\d)?\z/.freeze

  # Durée restreinte à `[\d.]+` (pas `\S+`) : doit s'arrêter AVANT un éventuel
  # `-<doigté>` (Phil, 2026-08-26). Groupes 4/5 : doigté main droite (p/i/m/a/c),
  # doigté main gauche (chiffre) — ex. "60/4-p2" (corde6 case0 noire, pouce + 2e doigt).
  CORDE_CASE_RE = %r{\A([1-6])(\d+)(?:/([\d.]+))?(?:-([pimac])?(\d)?)?\z}.freeze
  CHORD_RE = %r{\A(\w+)?<([^>]+)>(?:/(\S+))?\z}.freeze
  # `r<durée>` (silence visible) / `s<durée>` (silence invisible, "skip" — compte pour
  # le placement des barres sans être marqué, typiquement une levée) — syntaxe LilyPond
  # brute, valide telle quelle, aucune traduction corde/case nécessaire.
  REST_RE = /\A([rs])(\S+)\z/.freeze
  # Barres de mesure façon LilyPond (`\bar "..."`) — simple, fin de morceau, double
  # (fin de partie), reprises (Phil, 2026-08-26 : les 6 formes d'un coup).
  BAR_RE = /\A(\|\.|\|\||:\|:|:\||\|:|\|)\z/.freeze

  class ParseError < StandardError; end

  module_function

  def midi_to_lily(midi)
    semitone = midi % 12
    octave = (midi / 12) - 1 # MIDI 60 (do4) -> octave LilyPond 4
    marks = octave - 3 # "c" nu = do3
    name = NOTE_NAMES[semitone]
    name += marks.positive? ? "'" * marks : ',' * (-marks) if marks != 0
    name
  end

  def corde_case_midi(corde, case_num)
    base = OPEN_STRING_MIDI.fetch(corde) { raise ParseError, "corde inconnue : #{corde}" }
    base + case_num
  end

  def corde_case_to_note(corde, case_num)
    "#{midi_to_lily(corde_case_midi(corde, case_num))}\\#{corde}"
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

  CONFIG_FILENAME = 'chordpro.json'

  # Remonte les dossiers depuis `dir` à la recherche de chordpro.json — même
  # fichier de config que ChordPro, pour un aspect uniforme entre les deux outils.
  def find_project_config(dir)
    dir = File.expand_path(dir)
    loop do
      path = File.join(dir, CONFIG_FILENAME)
      return path if File.exist?(path)

      parent = File.dirname(dir)
      return nil if parent == dir

      dir = parent
    end
  end

  def load_config(path)
    return {} unless path && File.exist?(path)

    # Tolère les commentaires "// ..." comme les fichiers ChordPro.
    raw = File.read(path).each_line.map { |l| l.sub(%r{//.*$}, '') }.join
    JSON.parse(raw)
  end

  # Analyse pdf.fonts.<clé> du config ChordPro (chaîne "Famille [bold] [italic]
  # taille", ou objet {description:/name:/size:}) en {famille:, gras:, italique:, taille:}.
  def parse_font(config, cle)
    spec = config.dig('pdf', 'fonts', cle)
    return nil unless spec

    desc = spec.is_a?(String) ? spec : (spec['description'] || spec['name'])
    return nil unless desc

    mots = desc.split(/\s+/)
    taille = mots.last =~ /\A\d+(\.\d+)?\z/ ? mots.pop.to_f : nil
    gras = !!mots.delete('bold')
    italique = !!mots.delete('italic')
    famille = mots.join(' ')
    return nil if famille.empty?

    { famille: famille, gras: gras, italique: italique, taille: taille }
  end

  # LilyPond en mode `-dcrop` supprime l'espacement entre systèmes quels que soient les
  # réglages `system-system-spacing`/`\layout` — bug DOCUMENTÉ, pas une mauvaise config
  # (vérifié 2026-08-27 sur 4 réglages distincts, sortie strictement identique ; voir
  # lists.gnu.org/archive/html/lilypond-user/2021-01/msg00104.html). Contournement retenu
  # (Phil, 2026-08-27) : chaque `.tab` est PRÉ-DÉCOUPÉ en fragments de N mesures
  # (`split_into_fragments`/`PageBuilder.ensure_tabla_fragments`), rendu chacun
  # SÉPARÉMENT — un fragment = un système, jamais concerné par le bug. `line-break-
  # permission = ##f` : garantit qu'un fragment reste bien UN système même si notre
  # calcul de N (`PageBuilder.measures_per_page`) surestime légèrement la place
  # disponible — l'empilement + l'écart entre fragments (`tabla_system_spacing`) sont
  # ensuite gérés côté app (`Layout.build_tabla_fragments_element`), pas par LilyPond.
  # `Bar_number_engraver` retiré : les numéros de mesure n'ont aucun sens ici (Phil :
  # "retirer l'affichage des numéros de mesures").
  # `set-global-staff-size` FIXÉE en dur (Phil, 2026-08-27 : "peut-on définir, de façon
  # fixe, l'écartement des lignes ?") — 20pt = défaut LilyPond, valeur explicite plutôt
  # que de compter implicitement sur le fait qu'elle ne change jamais entre deux appels ;
  # `PageBuilder::SLOT_WIDTH_PT`/`SLOT_OVERHEAD_PT` (calibrés empiriquement) en dépendent.
  STAFF_SIZE = 20

  # Mesures à largeur ÉGALE, quel que soit leur contenu rythmique (Phil, 2026-08-27 :
  # "les mesures n'étant pas de même longueur, les systèmes ne le sont pas non plus").
  # Pas de propriété LilyPond native pour ça (vérifié — lilypond-user@gnu.org,
  # "Fixed Measure Widths" : solutions de contournement seulement). Retenu :
  # `proportionalNotationDuration`, espacement STRICTEMENT proportionnel au temps —
  # comme chaque mesure dure exactement UNE mesure entière (découpe par durée,
  # `split_into_duration_measures`, jamais un fragment de mesure), même temps = même
  # largeur, sans bidouille de voix invisible. Testé isolément (3 mesures, densités de
  # notes très différentes) : largeurs identiques confirmées.
  LAYOUT_BLOCK = <<~LY
    #(set-global-staff-size #{STAFF_SIZE})
    \\paper {
      indent = 0
    }
    \\layout {
      \\context {
        \\Score
        \\remove "Bar_number_engraver"
        \\override NonMusicalPaperColumn.line-break-permission = ##f
        proportionalNotationDuration = #(ly:make-moment 1 16)
      }
    }
  LY

  # Bloc \paper qui enregistre les polices réelles sous les alias LilyPond
  # "sans" (accords) et "roman" (texte, ex: capo) — requis par LilyPond
  # (set-global-fonts) avant de pouvoir les utiliser dans un markup.
  def fonts_paper_block(chord_font, text_font)
    return '' unless chord_font || text_font

    args = []
    args << "#:sans \"#{chord_font[:famille]}\"" if chord_font
    args << "#:roman \"#{text_font[:famille]}\"" if text_font

    <<~PAPER
      \\paper {
        #(define fonts (set-global-fonts #{args.join(' ')} #:factor (/ staff-height pt 20)))
      }
    PAPER
  end

  # Chaîne de commandes markup (police/graisse/style/taille) pour un élément
  # de texte donné (accords = alias "sans", texte = alias "roman").
  def markup_prefix(font, alias_lily)
    return '' unless font

    cmds = ["\\override #'(font-family . #{alias_lily})"]
    cmds << '\\bold' if font[:gras]
    cmds << '\\italic' if font[:italique]
    cmds << "\\abs-fontsize ##{font[:taille].to_i}" if font[:taille]
    "#{cmds.join(' ')} "
  end

  # Reconnaît un nom d'accord explicite, ex: [Am7], qui prime sur le calcul auto.
  EXPLICIT_CHORD_RE = /\A\[(.+)\]\z/.freeze

  # Classes de hauteurs (0..11) d'un token accord <c:f c:f ...>, ou nil si ce
  # n'en est pas un.
  def chord_midis(token)
    m = CHORD_RE.match(token) or return nil
    m[2].split(/\s+/).map do |pair|
      cm = CORDE_CASE_RE.match(pair) or raise ParseError, "note d'accord illisible : #{pair}"
      corde_case_midi(cm[1].to_i, cm[2].to_i)
    end
  end

  # Empile main droite (texte) / main gauche (`\finger`, rendu natif LilyPond) sur une
  # articulation NEUTRE (`-`) — Phil, 2026-08-26 : "laisse Lilypond décider" du
  # placement (au-dessus/en dessous), jamais forcé (`^`/`_`) côté code.
  def fingering_markup(rh, lh)
    return '' unless rh || lh

    parts = []
    parts << "\"#{rh}\"" if rh
    parts << "\\finger \"#{lh}\"" if lh
    "-\\markup \\column { #{parts.join(' ')} }"
  end

  # Convertit un token du corps en fragment LilyPond.
  def convert_token(token, notes_mode:)
    return "\\bar \"#{token}\"" if BAR_RE.match?(token)
    return token if REST_RE.match?(token)

    if notes_mode
      raise ParseError, "token illisible en mode notes : #{token}" unless token =~ NOTE_TOKEN_RE

      return token
    end

    if (m = CHORD_RE.match(token))
      prefix, inner, duree = m.captures
      notes = inner.split(/\s+/).map do |pair|
        cm = CORDE_CASE_RE.match(pair) or raise ParseError, "note d'accord illisible : #{pair}"
        corde_case_to_note(cm[1].to_i, cm[2].to_i)
      end
      chord = "<#{notes.join(' ')}>#{duree}"
      chord += '\arpeggio' if prefix == 'Arp'
      return chord
    end

    if (m = CORDE_CASE_RE.match(token))
      corde, kase, duree, rh, lh = m.captures
      note = corde_case_to_note(corde.to_i, kase.to_i)
      note = note.sub(/\\(\d)\z/, "#{duree}\\\\\\1") if duree
      note += fingering_markup(rh, lh)
      return note
    end

    raise ParseError, "token illisible : #{token}"
  end

  # Dénominateur de durée LilyPond associé à chaque plus petite division saisissable
  # (frontmatter `unit:`, voir `TablatorAssistant::DURATIONS` — même table) — sert à
  # `PageBuilder.measures_per_page` pour calculer combien de mesures tiennent sur une
  # page (Phil, 2026-08-27).
  UNIT_DENOMINATOR = { 'noire' => 4, 'croche' => 8, 'double-croche' => 16, 'triple-croche' => 32 }.freeze

  # Découpe les tokens en mesures (séparées par une barre, les 6 formes — `BAR_RE`).
  # Sert à `render_measures` (placement du nom d'accord, `\bar`) — pas à la découpe en
  # fragments (`split_into_duration_measures`, ci-dessous), les tabs réels n'ayant
  # souvent qu'UNE seule barre malgré un contenu de plusieurs mesures (Phil, 2026-08-27 :
  # "les durées + la métrique suffisent", pas besoin de "|" partout).
  def split_into_measure_groups(tokens)
    tokens.slice_after { |t| BAR_RE.match?(t) }.to_a
  end

  # Durée d'un `[\d.]+` façon LilyPond, en temps (noire = 1) — N = 4/N temps, chaque
  # point ajoute la moitié de l'incrément précédent (formule standard : 2 - 0.5**dots).
  def duration_str_to_beats(dur_str)
    base = dur_str[/\A\d+/].to_i
    return 1.0 if base.zero?

    dots = dur_str.count('.')
    (4.0 / base) * (2 - (0.5**dots))
  end

  # Durée (en temps) d'UN token — `nil` si ce n'est pas un événement musical (barre,
  # nom d'accord explicite `[Am7]`...). `last_duration` : durée omise = reprise de la
  # précédente (Phil, "à la façon LilyPond"), comme au rendu (`convert_token`).
  def token_beats(token, last_duration)
    if (m = CORDE_CASE_RE.match(token))
      dur = m[3] || last_duration
      [duration_str_to_beats(dur), dur]
    elsif (m = CHORD_RE.match(token))
      dur = m[3] || last_duration
      [duration_str_to_beats(dur), dur]
    elsif (m = REST_RE.match(token))
      [duration_str_to_beats(m[2]), m[2]]
    else
      [0.0, last_duration]
    end
  end

  # Mesures RÉELLES (Phil, 2026-08-27) : accumulation des durées de chaque token contre
  # la métrique (`time`, "N/D" — 4 temps par mesure en 4/4), PAS le comptage des barres
  # explicites du code (souvent absentes/rares — le fichier ne définit qu'un total,
  # "0/4=1 temps, 4/4=4 temps/mesure" suffit à SAVOIR ce que contient chaque mesure).
  # Une barre explicite (`BAR_RE`) force quand même une coupure (mesure incomplète
  # volontaire, levée...), même si le compte de temps n'est pas atteint.
  def split_into_duration_measures(tokens, time)
    num, den = time.to_s =~ %r{\A(\d+)/(\d+)\z} ? [$1.to_i, $2.to_i] : [4, 4]
    target = num * (4.0 / den)

    groups = []
    current = []
    acc = 0.0
    last_duration = '4'
    tokens.each do |t|
      if BAR_RE.match?(t)
        # Barre juste après une mesure déjà bouclée par accumulation (Phil, 2026-08-26 :
        # la barre finale d'un fichier `.tab` qui n'en a qu'une) : rattachée au groupe
        # précédent, jamais un groupe fantôme à elle seule.
        if current.empty? && !groups.empty?
          groups.last << t
        else
          current << t
          groups << current
          current = []
        end
        acc = 0.0
        next
      end

      beats, last_duration = token_beats(t, last_duration)
      current << t
      acc += beats
      next if acc < target - 0.001

      groups << current
      current = []
      acc = 0.0
    end
    groups << current unless current.empty?
    groups
  end

  # Découpe le CODE (frontmatter + corps) en fragments de `measures_per_fragment`
  # mesures RÉELLES chacun (Phil, 2026-08-27 : "tu prends la tablature et tu découpes
  # le code en autant de fragments que nécessaire") — même frontmatter répété sur
  # chaque fragment, chacun rendu séparément (voir `page_builder.rb`,
  # `ensure_tabla_fragments`) : système LilyPond unique par fragment, jamais concerné
  # par le bug `-dcrop` qui supprime l'espacement entre systèmes (vérifié 2026-08-27,
  # lists.gnu.org/archive/html/lilypond-user/2021-01/msg00104.html).
  def split_into_fragments(content, measures_per_fragment)
    front = content.start_with?('---') ? content[/\A---\n.*?\n---\n/m] : ''
    meta, body = parse_frontmatter(content)
    groups = split_into_duration_measures(tokenize(body), meta['metrique'] || meta['time'] || '4/4')
    return [content] if groups.empty?

    groups.each_slice([measures_per_fragment.to_i, 1].max).map { |chunk| "#{front}#{chunk.flatten.join(' ')}\n" }
  end

  # Découpe les tokens en mesures (séparées par une barre, les 6 formes — `BAR_RE`,
  # pas seulement "|") et place, sur le premier événement de chaque mesure, le nom
  # d'accord — calculé depuis un éventuel groupe <...> présent n'importe où dans la
  # mesure, ou fourni explicitement via [Nom] (qui prime toujours sur le calcul).
  def render_measures(tokens, chord_names:, chord_font: '')
    mesures = split_into_measure_groups(tokens)
    mesures.map do |mesure|
      # `\bar "..."` (pas le token brut) : seul "|" est une syntaxe LilyPond bare
      # valide (bar check), les 5 autres formes ("|.", "||", ":|:"...) exigent `\bar`.
      bar = BAR_RE.match?(mesure.last.to_s) ? convert_token(mesure.pop, notes_mode: false) : nil

      override = nil
      notes_tokens = mesure.reject do |t|
        (m = EXPLICIT_CHORD_RE.match(t)) && (override = m[1])
      end

      label = override
      if chord_names && !label
        notes_tokens.each do |t|
          midis = chord_midis(t)
          next unless midis

          label = chord_label(midis.map { |m| m % 12 }, midis.min % 12)
          break
        end
      end

      converted = notes_tokens.map { |t| convert_token(t, notes_mode: false) }
      converted[0] = "#{converted[0]}^\\markup{ #{chord_font}\"#{label}\" }" if label && converted[0]
      [converted.join(' '), bar].compact.join(' ')
    end.join(' ')
  end

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

  # Métrique en chiffres empilés façon LilyPond, mais avec un peu d'écart
  # entre les deux chiffres (le style par défaut de LilyPond les fait se
  # toucher) — via un stencil markup \center-column plutôt que le glyphe
  # standard.
  def time_signature_block(time)
    return '' unless time

    num, den = time.split('/')
    return "\\time #{time}" unless den

    <<~LY
      \\override Staff.TimeSignature.stencil = #ly:text-interface::print
      \\override Staff.TimeSignature.text = \\markup \\override #'(baseline-skip . 1.65) \\center-column { "#{num}" "#{den}" }
      \\time #{time}
    LY
  end

  # "1" -> "1er", "4" -> "4e", etc.
  def ordinal_fr(n)
    n.to_i == 1 ? '1er' : "#{n}e"
  end

  def capo_mark(capo, text_font)
    return '' unless capo

    "\\mark \\markup{ #{markup_prefix(text_font, 'roman')}\"Capo : #{ordinal_fr(capo)}\" }"
  end

  def to_lilypond(content, notes_mode:, base_dir: Dir.pwd)
    meta, body = parse_frontmatter(content)
    tokens = tokenize(body)
    config = load_config(find_project_config(base_dir))
    chord_font = parse_font(config, 'chord')
    text_font = parse_font(config, 'text')
    music =
      if notes_mode
        tokens.map { |t| convert_token(t, notes_mode: true) }.join(' ')
      else
        render_measures(tokens, chord_names: !!meta['chord'], chord_font: markup_prefix(chord_font, 'sans'))
      end
    time = meta['metrique'] || meta['time']
    stem_direction = meta['chord'] ? '\\stemDown' : '\\stemUp'

    <<~LY
      \\version "#{LILYPOND_VERSION}"
      #(ly:set-option 'crop #t)
      \\header { tagline = ##f }
      #{LAYOUT_BLOCK}
      #{fonts_paper_block(chord_font, text_font)}
      \\new TabStaff {
        \\tabFullNotation
        \\omit Staff.Clef
        #{stem_direction}
        #{time_signature_block(time)}
        { #{capo_mark(meta['capo'], text_font)} #{music} }
      }
    LY
  end

  def render_svg(ly_source, out_base)
    Dir.mktmpdir do |dir|
      src = File.join(dir, 'tab.ly')
      File.write(src, ly_source)

      cmd = ['lilypond', '-dno-point-and-click', '--svg', '--silent', '-o', File.join(dir, 'tab'), src]
      system(*cmd, out: File::NULL, err: File::NULL) or raise "échec de lilypond (#{cmd.join(' ')})"

      produced = File.join(dir, 'tab.cropped.svg')
      raise 'lilypond n\'a produit aucun SVG' unless File.exist?(produced)

      FileUtils.cp(produced, "#{out_base}.svg")
    end
  end
end

# --- CLI ---------------------------------------------------------------

if $PROGRAM_NAME == __FILE__
  options = { notes: false }
  parser = OptionParser.new do |o|
    o.banner = 'Usage: tablator [options] [fichier.tab]'
    o.on('-e CODE', 'Code brut en argument, au lieu d\'un fichier') { |v| options[:inline] = v }
    o.on('-o FICHIER', 'Base du fichier de sortie (.svg et .ly ajoutés)') { |v| options[:out] = v }
    o.on('-n', '--notes', 'Entrée en notes classiques plutôt qu\'en corde:case') { options[:notes] = true }
  end
  parser.parse!

  input_path = ARGV.first
  input_path = "#{input_path}.tab" if input_path && !File.exist?(input_path) && !input_path.end_with?('.tab')

  content =
    if options[:inline]
      options[:inline]
    elsif input_path
      File.read(input_path)
    else
      $stdin.read
    end

  out_base = options[:out] || (input_path ? input_path.sub(/\.\w+\z/, '') : 'out')

  begin
    meta, = Tablator.parse_frontmatter(content)
    base_dir = input_path ? File.dirname(File.expand_path(input_path)) : Dir.pwd
    ly = Tablator.to_lilypond(content, notes_mode: options[:notes], base_dir: base_dir)
    File.write("#{out_base}.ly", ly) if meta['keep_ly']
    Tablator.render_svg(ly, out_base)
    warn(input_path ? "Tabulation de #{File.basename(input_path)} produite en SVG" : 'Tabulation produite en SVG')
  rescue Tablator::ParseError => e
    warn "Erreur de syntaxe : #{e.message}"
    exit 1
  end
end
