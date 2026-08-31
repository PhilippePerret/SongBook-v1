require "fileutils"
require_relative "file_finder"
require_relative "layout"
require_relative "../tools/ChordDiagram/generate_chord_diagrams"

# Avant toute construction (carnet ou chanson seule) : lit le `.schemas`/`.sch` de
# `dir` s'il existe, régénère chaque SVG absent OU plus vieux que ce fichier (un seul
# fichier pour tous les accords, comparaison de date au niveau du fichier entier, pas
# accord par accord — . Toujours écrit dans `images/diags/` DANS `dir`,
# même si l'user a déjà placé des SVG ailleurs (bonnes habitudes) — `ChordDiagrams`
# cherche ensuite dans TOUT `dir`, pas seulement `images/diags/` (l'user peut les avoir
# mis n'importe où).
module DiagsSync
  OUT_SUBDIR = File.join("images", "diags")

  def self.sync!(dir)
    return unless dir

    schema_path = FileFinder.find(dir, :sch)
    return unless schema_path

    schema_mtime = File.mtime(schema_path)
    out_dir = File.join(dir, OUT_SUBDIR)

    File.read(schema_path).each_line do |line|
      line = line.strip
      next if line.empty?

      m = GenerateChordDiagrams::LINE_RE.match(line)
      unless m
        Layout.conflict!("schéma illisible (#{schema_path}) : #{line}", solution: "ligne ignorée")
        next
      end

      name, kase, tokens_str = m[1], m[2], m[3]
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
    end
  end
end
