# frozen_string_literal: true

require_relative "app_config"
require_relative "file_finder"
require_relative "song_cache"
require_relative "carnet_builder"

# `songbook songs` : liste filtrable de TOUTES les chansons (ou d'un seul carnet via
# `--sb/--songbook`), pour choisir une chanson puis une action à lui appliquer.
module SongsList
  def self.entries(carnet_folder: nil)
    chansons_dir = AppConfig.songs_dir
    names = carnet_folder ? tdm_names(carnet_folder) : song_folder_names(chansons_dir)
    names.filter_map { |name| SongCache.resolve(chansons_dir, name) }
  end

  def self.song_folder_names(chansons_dir)
    Dir.children(chansons_dir).select do |entry|
      folder = File.join(chansons_dir, entry)
      File.directory?(folder) && FileFinder.find(folder, :lyr)
    end
  end

  def self.tdm_names(carnet_folder)
    tdm_path = FileFinder.find(carnet_folder, :tdm)
    return [] unless tdm_path

    File.readlines(tdm_path).map { |l| l.sub(/\A-\s*/, "").strip }.reject(&:empty?)
  end

  # `key` : "alpha" (défaut), "year" (année puis alpha), "performer" (interprète puis
  # alpha) — toute autre valeur retombe sur "alpha" (Phil, 2026-08-30).
  def self.sort(entries, key)
    case key
    when "year"
      entries.sort_by { |e| [e[:infos]["year"].to_s, alpha_key(e[:infos]["title"])] }
    when "performer"
      entries.sort_by { |e| [alpha_key(e[:infos]["performer"]), alpha_key(e[:infos]["title"])] }
    else
      entries.sort_by { |e| alpha_key(e[:infos]["title"]) }
    end
  end

  # Tri alphabétique correct (Phil, 2026-08-30, `_dev/specs/specs.md`) : article défini
  # de tête retiré ("le"/"la"/"les"/"l'" — `CarnetBuilder::ARTICLE_HEAD_RE`, PAS "un"/
  # "des", volontairement gardés), accents neutralisés (`CarnetBuilder.slugify`).
  def self.alpha_key(text)
    CarnetBuilder.slugify(text.to_s.sub(CarnetBuilder::ARTICLE_HEAD_RE, ""))
  end

  # Texte accent-neutre pour un filtrage insensible aux accents (Phil, 2026-08-30) —
  # SANS toucher aux espaces/ponctuation (contrairement à `alpha_key`, réservé au tri) :
  # une regex tapée avec un espace doit continuer à matcher normalement.
  def self.fold_accents(text)
    text.to_s.unicode_normalize(:nfkd).encode("ASCII", invalid: :replace, undef: :replace, replace: "")
  end

  # "titre (performer, année)" (Phil, 2026-08-30) — parenthèse omise si les deux
  # manquent.
  def self.label(entry)
    infos = entry[:infos]
    extra = [infos["performer"], infos["year"]].reject { |v| v.to_s.strip.empty? }.join(", ")
    extra.empty? ? infos["title"].to_s : "#{infos["title"]} (#{extra})"
  end
end
