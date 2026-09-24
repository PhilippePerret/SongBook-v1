# frozen_string_literal: true

require "yaml"
require_relative "app_config"

# Base commune des éditeurs (`music_publisher`), partagée entre toutes les chansons —
# une chanson ne garde plus que son/ses IPI (clé de cette base), jamais plus les
# name/email/address/role dupliqués à chaque fiche (Phil, 2026-09-23, "je gardais juste
# l'IPI et une base YAML avec toutes les infos"). Fichier texte simple, éditable à la
# main (voir `RightsCli`).
module PublishersDb
  def self.path
    File.join(AppConfig.songs_dir, "publishers.yaml")
  end

  def self.all
    File.exist?(path) ? (YAML.safe_load_file(path) || {}) : {}
  end

  def self.find(key)
    all[key.to_s]
  end

  # Fusionne `fields` dans l'entrée `key` (créée si absente) — jamais un champ déjà
  # renseigné écrasé par une valeur vide (une recherche Sacem ultérieure sans email connu
  # ne doit pas effacer un email ajouté à la main).
  def self.upsert!(key, fields)
    key = key.to_s.strip
    return if key.empty?

    data = all
    existing = data[key].is_a?(Hash) ? data[key] : {}
    incoming = fields.transform_keys(&:to_s).reject { |_, v| v.to_s.strip.empty? }
    data[key] = existing.merge(incoming)
    File.write(path, YAML.dump(data))
  end
end
