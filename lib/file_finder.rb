# Recherche d'un fichier par type, root-name libre (n'importe quel préfixe, ou aucun :
# ".ext" tout court). `Dir.glob("*.ext")` seul ne suffit JAMAIS : Ruby exclut les
# dotfiles du `*` par défaut, donc un fichier nommé exactement ".ext" (sans root) ne
# serait jamais trouvé — bug constaté 2026-08-21. Chaque type accepte une forme longue
# ET une forme courte (Phil, 2026-08-21) — les deux valables indifféremment. Clé =
# toujours la forme courte (Phil, 2026-08-21).
module FileFinder
  EXTENSIONS = {
    gab: %w[gabarit gab],
    inf: %w[infos inf],
    tdm: %w[tdm toc],
    lyr: %w[lyrics lyr],
    lay: %w[layout lay],
    sch: %w[schemas sch],
  }.freeze

  def self.find(dir, kind)
    EXTENSIONS.fetch(kind).each do |ext|
      path = Dir.glob(File.join(dir, "*.#{ext}")).first
      path ||= File.join(dir, ".#{ext}") if File.exist?(File.join(dir, ".#{ext}"))
      return path if path
    end
    nil
  end
end
