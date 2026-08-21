require "yaml"

# Locale de l'utilisateur chargée UNE SEULE FOIS pour toute l'appli — langue système
# (`LANG`), ou forcée via `--lang=xx` en argument. `Loc.get(cle)` lit dans le `loc.yaml`
# de cette langue (`Locales/<lang>/loc.yaml`, clé/valeur PLATES) ; clé absente -> la clé
# elle-même (jamais nil, jamais de crash).
class Loc
  DIR = File.expand_path("../Locales", __dir__)
  DEFAULT_LANG = "fr"

  forced = ARGV.find { |a| a.start_with?("--lang=") }
  system_lang = ENV["LANG"].to_s[0, 2]
  LANG = forced ? forced.split("=", 2).last : (system_lang.empty? ? DEFAULT_LANG : system_lang)

  path = File.join(DIR, LANG, "loc.yaml")
  @table = File.exist?(path) ? (YAML.safe_load_file(path) || {}) : {}

  def self.get(key)
    @table[key] || key
  end
end
