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

  CORDE_CASE_RE = %r{\A([1-6])(\d+)(?:/(\S+))?\z}.freeze
  CHORD_RE = %r{\A(\w+)?<([^>]+)>(?:/(\S+))?\z}.freeze

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

  # Convertit un token du corps en fragment LilyPond.
  def convert_token(token, notes_mode:)
    return token if token == '|'

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
      corde, kase, duree = m.captures
      note = corde_case_to_note(corde.to_i, kase.to_i)
      return note.sub(/\\(\d)\z/, "#{duree}\\\\\\1") if duree

      return note
    end

    raise ParseError, "token illisible : #{token}"
  end

  # Découpe les tokens en mesures (séparées par "|") et place, sur le premier
  # événement de chaque mesure, le nom d'accord — calculé depuis un éventuel
  # groupe <...> présent n'importe où dans la mesure, ou fourni explicitement
  # via [Nom] (qui prime toujours sur le calcul).
  def render_measures(tokens, chord_names:, chord_font: '')
    mesures = tokens.slice_after { |t| t == '|' }.to_a
    mesures.map do |mesure|
      bar = mesure.last == '|' ? mesure.pop : nil

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
