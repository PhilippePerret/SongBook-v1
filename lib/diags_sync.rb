require "fileutils"
require_relative "file_finder"
require_relative "layout"
require_relative "../tools/ChordDiagram/generate_chord_diagrams"

# Avant toute construction (carnet ou chanson seule) : lit le `.schemas`/`.sch` de
# `dir` s'il existe, régénère chaque SVG absent OU plus vieux que ce fichier (un seul
# fichier pour tous les accords, comparaison de date au niveau du fichier entier, pas
# accord par accord — . Toujours écrit dans `scores/` DANS `dir`  (Phil : "c'est
# dans /scores, sans sous-dossier, qu'il faut mettre les diags produits pour la
# chanson" — MÊME dossier ressource que tabs/images, `PageBuilder::RESOURCE_SUBDIRS`),
# même si l'user a déjà placé des SVG ailleurs (bonnes habitudes) — `ChordDiagrams`
# cherche ensuite dans TOUT `dir`, pas seulement `scores/` (l'user peut les avoir mis
# n'importe où).
module DiagsSync
  OUT_SUBDIR = "scores"

  # `{nom} : <6 tokens>` (SANS case) : l'user ne doit pas être obligé de choisir une
  # case juste pour nommer un accord — la case manquante est déduite (voir `sync!`),
  # jamais imposée. Même `nom` que `GenerateChordDiagrams::LINE_RE` (jamais de "-" dedans).
  NAME_ONLY_LINE_RE = /\A([^-:]+?)\s*:\s*(.+)\z/.freeze

  # Renvoie le nombre de SVG (re)générés (0 si rien à faire, `nil` si aucun `.schemas`/
  # `.sch` trouvé) — `Cli.cmd_build_diags` s'en sert pour signaler l'absence du fichier.
  def self.sync!(dir)
    return unless dir

    schema_path = FileFinder.find(dir, :sch)
    return unless schema_path

    schema_mtime = File.mtime(schema_path)
    out_dir = File.join(dir, OUT_SUBDIR)
    count = 0

    File.read(schema_path).each_line do |line|
      line = line.strip
      next if line.empty?

      m = GenerateChordDiagrams::LINE_RE.match(line)
      if m
        name, kase, tokens_str = m[1], m[2], m[3]
      elsif (m = NAME_ONLY_LINE_RE.match(line))
        name, tokens_str = m[1].strip, m[2]
        kase = smallest_case(tokens_str)
      else
        Layout.conflict!("schéma illisible (#{schema_path}) : #{line}", solution: "ligne ignorée")
        next
      end

      svg_path = File.join(out_dir, "#{name}-#{kase}.svg")
      next if File.exist?(svg_path) && File.mtime(svg_path) >= schema_mtime

      begin
        svg = GenerateChordDiagrams.build(name: name, tokens_str: tokens_str)
      rescue RuntimeError => e
        Layout.conflict!("génération diagramme #{name}-#{kase} impossible (#{schema_path}) : #{e.message}", solution: "SVG omis")
        next
      end

      FileUtils.mkdir_p(out_dir)
      File.write(svg_path, svg)
      Layout.log_build("diagramme #{name}-#{kase} (re)généré depuis #{schema_path}")
      count += 1
    end
    count
  end

  # Case déduite des tokens de LA ligne elle-même : la case n'est PAS la frette la plus
  # basse parmi les frettées seules — une corde à VIDE (frette 0) fait tomber toute la
  # case à "0" (position ouverte, près du sillet), quelles que soient les autres frettes
  # plus hautes (F6 sans corde à vide -> case = sa plus basse frette jouée = 1 ; G7 avec
  # une corde à vide -> case = 0, même si ses autres cordes montent à 3). Donc : le MIN de
  # toutes les frettes NON étouffées (0 inclus), jamais exclu. "0" si tout est étouffé.
  def self.smallest_case(tokens_str)
    frets = tokens_str.split.filter_map do |t|
      m = GenerateChordDiagrams::TOKEN_RE.match(t)
      m && m[3] != "x" ? m[3].to_i : nil
    end
    (frets.min || 0).to_s
  end
end
