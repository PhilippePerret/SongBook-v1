require_relative "chord_diagram"
require_relative "../../lib/transpose"

# Lit les `schemas.txt` (un par dossier de lettre :
# "<Nom>-<case> : <6 tokens>", un token par corde 1(aiguë/e)..6(grave/E), chaque token
# "<corde><frette>[/<doigt>]", frette = 0-15 ou "x" (étouffée). Génère le SVG manquant
# correspondant, jamais ceux déjà présents — sauf `force:` (voir `run`), qui régénère
# tout.
module GenerateChordDiagrams
  # Parenthèses autour d'un token entier : note FACULTATIVE (même doigt qu'une autre
  # corde, qui peut s'étendre là en plus) — NE COMPTE JAMAIS pour la détection de barré,
  # même si elle partage frette et doigt avec une autre corde .
  TOKEN_RE = /\A(\()?([1-6])(x|\d{1,2})(?:\/(\w+))?(\))?\z/
  # Nom = tout ce qui précède le PREMIER "-" (jamais de "-" dans un nom d'accord) ; case
  # = tout le reste, n'importe quoi, jamais limité au numérique (`SchemaLibrary::ENTRY_RE`,
  # même règle).
  LINE_RE = /\A([^-]+)-(\S+)\s*:\s*(.+)\z/

  # Nom AFFICHÉ (pas le nom de fichier) : "d"/"b" en 2e lettre = dièse/bémol (♯/♭,
  # convention historique pré-UTF8 du projet), SAUF "dim" (accord diminué — "d" suivi
  # de "im" reste "dim", jamais "♯im"). .
  def self.display_name(raw)
    root = raw[0]
    rest = raw[1..] || ""
    if rest.start_with?("d") && rest[1, 2] != "im"
      "#{root}♯#{rest[1..]}"
    elsif rest.start_with?("b")
      "#{root}♭#{rest[1..]}"
    else
      raw
    end
  end

  def self.parse_token(str)
    m = TOKEN_RE.match(str) or raise "token illisible : #{str.inspect}"
    string = m[2].to_i
    fret = m[3] == "x" ? :muted : m[3].to_i
    { string: string, fret: fret, finger: m[4], optional: !!(m[1] && m[5]) }
  end

  # Grand barré (specs.md : corde 1 à 6) détecté quand 2+ cordes NON facultatives
  # partagent la frette la plus basse de l'accord ET LE MÊME DOIGT — explicite (répété,
  # comme F désormais) OU omis partout dans le groupe (implicite, alors doigt "1" par
  # défaut). Une corde à cette même frette mais avec un doigté DIFFÉRENT et explicite
  # (ex. G-3, corde sol, doigt 2) n'appartient PAS au barré — juste une note qui tombe
  # sur la même frette, gardée telle quelle (bug trouvé et corrigé, 2026-08-17).
  #
  # `indices` (cordes candidates réelles) sert à masquer leur point/chiffre individuel
  # — jamais les autres cordes de l'intervalle, qui gardent leur propre note même plus
  # haute (comme pour F). `span` sert SEULEMENT à la ligne dessinée, bornée aux
  # candidates SAUF s'il y a un "trou" (corde non-candidate strictement entre la plus
  # basse et la plus haute des cordes candidates) qui est elle-même frettée ailleurs
  # (note individuelle plus haute, cas F/Dm6-5) : un doigt à plat ne peut alors
  # physiquement tenir les deux cordes de part et d'autre du trou sans aussi couvrir
  # celle du trou, donc le span est étendu jusqu'aux cordes extrêmes du groupe
  # (min..max des `indices`, ex. E9b-7 : cordes 2 et 4 barrées séparées par la corde 3
  # frettée ailleurs -> span 2-3-4, jamais 1-6). Si le trou est une corde à vide (0) ou
  # étouffée (x) — jamais frettée nulle part —, ou s'il n'y a simplement AUCUN trou
  # (candidates déjà contiguës, même 2/3/4 cordes, ex. D7M-0 : cordes 1-2-3 barrées,
  # 4/5/6 à vide/étouffées, hors du span, rien à couvrir), le span reste borné aux
  # candidates — jamais promu (bug trouvé sur D7M-0, 2026-08-19 : le repli sur 6 cordes
  # dessinait alors un barré traversant des cordes à vide, impossible aussi).
  # Décode "<6 tokens>" en {positions:, fingers:, barre:, optionals:}, prêt pour
  # `ChordDiagram.build`.
  def self.decode(tokens_str)
    tokens = tokens_str.split.map { |t| parse_token(t) }

    fretted = tokens.reject { |t| t[:optional] }.select { |t| t[:fret].is_a?(Integer) && t[:fret].positive? }
    barre = nil
    if fretted.size >= 2
      min_fret = fretted.map { |t| t[:fret] }.min
      at_min_fret = fretted.select { |t| t[:fret] == min_fret }
      groups = at_min_fret.group_by { |t| t[:finger] || :implicit }
      key, candidates = groups.max_by { |_, v| v.size }
      if candidates.size >= 2
        strings = candidates.map { |t| t[:string] }
        min_s, max_s = strings.minmax
        indices = candidates.map { |t| 6 - t[:string] }
        gap_strings = ((min_s..max_s).to_a - strings)
        gap_fretted = gap_strings.any? { |s| fretted.any? { |t| t[:string] == s } }
        span = gap_fretted ? (indices.min..indices.max).to_a : indices
        barre = { fret: min_fret, finger: key == :implicit ? "1" : key, indices: indices, span: span }
      end
    end

    positions = Array.new(6)
    fingers = Array.new(6)
    optionals = Array.new(6, false)
    tokens.each do |t|
      idx = 6 - t[:string]
      positions[idx] = t[:fret] == :muted ? :muted : (t[:fret].zero? ? :open : t[:fret])
      optionals[idx] = t[:optional]
      next if t[:fret] == :muted || t[:fret].zero?
      next if barre && barre[:indices].include?(idx)

      fingers[idx] = t[:finger]
    end

    { positions: positions, fingers: fingers, barre: barre, optionals: optionals }
  end

  # "D[Fd]" (convention filename, specs.md) -> ["D", "Fd"] (accord, basse). Pas de
  # crochet -> pas de basse.
  def self.parse_name(raw)
    m = /\A([^\[]+)(?:\[([^\]]+)\])?\z/.match(raw)
    [m[1], m[2]]
  end

  def self.build(name:, tokens_str:)
    root, bass = parse_name(name)
    d = decode(tokens_str)
    ChordDiagram.build(name: display_name(root), positions: d[:positions], fingers: d[:fingers], barre: d[:barre], bass: bass && Transpose.italian_bass_symbol(bass), optionals: d[:optionals])
  end

  # Plus de versionnement  : un accord à actualiser se met à
  # jour en détruisant son SVG, ce module le refabrique alors automatiquement.
  def self.svg_path(dir, name, kase)
    File.join(dir, "#{name}-#{kase}.svg")
  end

  def self.existing?(dir, name, kase)
    File.exist?(svg_path(dir, name, kase))
  end

  # Renvoie la liste des fichiers créés : [{path:, name:, kase:}]. Une ligne mal
  # formée (ex. schema encore en cours d'écriture) n'arrête jamais le lot : elle est
  # rapportée à part (`skipped`), les autres lignes valides sont générées quand même.
  # `only:` restreint la génération à une liste d'accords (ex. ["Gsus-0", "A-0"]).
  # `force:` régénère TOUS les diags des `schemas.txt` (écrase les SVG existants,
  # "update diags" doit actualiser, pas seulement compléter) — sans lui (défaut),
  # seuls les diags manquants sont générés.
  def self.run(root = File.expand_path("../../assets/chords_diags", __dir__), only: nil, force: false)
    created = []
    skipped = []
    Dir.glob(File.join(root, "*", "schemas.txt")).sort.each do |schema_path|
      dir = File.dirname(schema_path)
      File.read(schema_path).each_line do |line|
        line = line.strip
        next if line.empty?

        m = LINE_RE.match(line)
        unless m
          skipped << { schema_path: schema_path, line: line }
          next
        end

        name, kase, tokens_str = m[1], m[2], m[3]
        next if only && !only.include?("#{name}-#{kase}")
        next if !force && existing?(dir, name, kase)

        begin
          svg = build(name: name, tokens_str: tokens_str)
        rescue RuntimeError => e
          skipped << { schema_path: schema_path, line: line, error: e.message }
          next
        end
        out_path = svg_path(dir, name, kase)
        File.write(out_path, svg)
        created << { path: out_path, name: name, kase: kase }
      end
    end
    [created, skipped]
  end
end
