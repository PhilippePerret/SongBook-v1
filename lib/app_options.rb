require "yaml"

# Options par défaut de l'application (Manuel/app/options.adoc) — `SongBook-app/options.yaml`,
# clé/valeur plates, chargé une seule fois. Un carnet surcharge via son `.infos`/`.inf`
# (ex. `front_matter.table_of_contents.position` surcharge `tdm_position`).
module AppOptions
  PATH = File.expand_path("../options.yaml", __dir__)

  CM_TO_PT = 72.0 / 2.54
  MM_TO_PT = CM_TO_PT / 10.0
  IN_TO_PT = 72.0

  def self.all
    @all ||= YAML.safe_load_file(PATH) || {}
  end

  def self.get(key)
    all[key.to_s]
  end

  # "1cm" -> 28.35, "10mm" -> 28.35, "0.5in" -> 36.0, "12pt" -> 12.0, "12" -> 12.0.
  def self.length_pt(value)
    case value.to_s.strip
    when /\A([\d.]+)\s*cm\z/ then $1.to_f * CM_TO_PT
    when /\A([\d.]+)\s*mm\z/ then $1.to_f * MM_TO_PT
    when /\A([\d.]+)\s*in\z/ then $1.to_f * IN_TO_PT
    when /\A([\d.]+)\s*pt\z/ then $1.to_f
    else value.to_f
    end
  end
end
