# Recherche d'un fichier par type, root-name libre (n'importe quel préfixe, ou aucun :
# ".ext" tout court). `Dir.glob("*.ext")` seul ne suffit JAMAIS : Ruby exclut les
# dotfiles du `*` par défaut, donc un fichier nommé exactement ".ext" (sans root) ne
# serait jamais trouvé — bug constaté 2026-08-21. Chaque type accepte une forme longue
# ET une forme courte  — les deux valables indifféremment. Clé =
# toujours la forme courte .
module FileFinder
  EXTENSIONS = {
    gab: %w[gabarit gab],
    inf: %w[infos inf],
    tdm: %w[tdm toc],
    lyr: %w[lyrics lyr],
    lay: %w[layout lay],
    sch: %w[schemas sch],
    cov: %w[cover cov],
  }.freeze

  # `<id[ index]>.infos` (override d'une entrée de .tdm répétée, `CarnetBuilder.
  # resolve_infos_override`) — un `.infos`/`.inf` PARMI D'AUTRES dans le même dossier
  # (carnet ou chanson) : jamais confondu avec le `.infos` de base cherché ici (root-name
  # libre, mais UN SEUL fichier "normal" attendu par dossier).
  REPEAT_OVERRIDE_RE = /\[[^\[\]]*\]\z/

  def self.find(dir, kind)
    EXTENSIONS.fetch(kind).each do |ext|
      candidates = Dir.glob(File.join(dir, "*.#{ext}")).sort
      candidates.reject! { |p| File.basename(p, ".*").match?(REPEAT_OVERRIDE_RE) } if kind == :inf
      path = candidates.first
      path ||= File.join(dir, ".#{ext}") if File.exist?(File.join(dir, ".#{ext}"))
      return path if path
    end
    nil
  end

  # Racine reprise du nom le PLUS UTILISÉ parmi les fichiers déjà présents (ex. "c.lyr"
  # + "c.infos" -> "c") — "c" par défaut si le dossier est vide. Jamais de fichier
  # créé sans root-name (".ext" = fichier masqué dans le Finder).
  def self.most_common_root(folder)
    exts = EXTENSIONS.values.flatten
    roots = Dir.glob(File.join(folder, "*.{#{exts.join(',')}}")).map { |p| File.basename(p, ".*") }
    return "c" if roots.empty?

    roots.tally.max_by { |_, count| count }.first
  end
end
