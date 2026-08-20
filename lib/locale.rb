require "yaml"

# Fichiers `Locales/<lang>/<file>.yaml`, clé/valeur PLATES (pas d'imbrication, pas de path
# à séparer — Phil, 2026-08-20). `loc.yaml` : termes affichés (ex. libellés des rôles du
# colophon). `infos_keys.yaml` : alias -> clé canonique pour les `.infos` de chanson
# écrits dans une autre langue (ex. `performer` -> `interprete`).
module Locale
  DIR = File.expand_path("../Locales", __dir__)
  DEFAULT_LANG = "fr"

  @cache = {}

  # Chargé une seule fois par (langue, fichier) — mémoïsé. Hash vide si le fichier
  # n'existe pas (langue non traduite : `t` retombe alors sur `default`/la clé elle-même).
  def self.load(lang, file: "loc")
    @cache[[lang, file]] ||= begin
      path = File.join(DIR, lang, "#{file}.yaml")
      File.exist?(path) ? (YAML.safe_load_file(path) || {}) : {}
    end
  end

  # "book_designer" -> cherche dans `lang`, puis `DEFAULT_LANG`, puis `default` (donné par
  # l'appelant), puis renvoie `key` tel quel en dernier recours — jamais nil, jamais de
  # crash sur une traduction manquante.
  def self.t(key, lang: DEFAULT_LANG, file: "loc", default: nil)
    load(lang, file: file)[key] || load(DEFAULT_LANG, file: file)[key] || default || key
  end
end
