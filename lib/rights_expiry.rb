# frozen_string_literal: true

require "date"
require_relative "app_config"
require_relative "songs_list"
require_relative "file_finder"
require_relative "carnet_builder"
require_relative "ansi_colors"

# Les droits de reproduction accordés ne sont jamais à vie — une fois le statut
# `contract_signed` (durée + date de départ fixée au contrat), ils expirent. Ce module
# vérifie l'expiration UNE FOIS PAR JOUR SEULEMENT (Phil, 2026-09-22), sur TOUTE la
# bibliothèque, au lancement de `songbook` (`CLI.run`) — jamais plus d'une fois/jour même
# si la commande est relancée plusieurs fois (état persisté, voir `last_check_path`).
module RightsExpiry
  extend AnsiColors

  LAST_CHECK_FILE = ".rights_expiry_last_check"
  DURATION_RE = /\A(\d+)\s*(ans?|mois|jours?)\z/i
  UNIT_LABELS = { "an" => "ans", "ans" => "ans", "mois" => "mois", "jour" => "jours", "jours" => "jours" }.freeze

  def self.check_once_per_day!
    return unless due_today?

    expired = scan_expired
    mark_checked!
    report(expired) unless expired.empty?
  rescue StandardError
    nil # jamais casser une commande normale pour ce contrôle de confort
  end

  def self.last_check_path
    File.join(AppConfig.songs_dir, LAST_CHECK_FILE)
  end

  def self.due_today?
    !File.exist?(last_check_path) || File.read(last_check_path).strip != Date.today.iso8601
  end

  def self.mark_checked!
    File.write(last_check_path, Date.today.iso8601)
  end

  def self.scan_expired
    SongsList.entries.filter_map do |e|
      infos_path = FileFinder.find(File.join(AppConfig.songs_dir, e[:folder]), :inf)
      next unless infos_path

      infos = CarnetBuilder.parse_nested_infos(infos_path)
      rights = infos["reproduction_rights"]
      next unless rights.is_a?(Hash) && rights["status"] == "contract_signed"

      expiry = expiry_date(rights)
      next unless expiry && expiry < Date.today

      { title: infos["title"].to_s, expiry: expiry }
    end
  end

  def self.expiry_date(rights)
    m = rights["duration"].to_s.match(DURATION_RE)
    return nil unless m

    start = begin
      Date.parse(rights["start_date"].to_s)
    rescue ArgumentError, TypeError
      nil
    end
    return nil unless start

    n = m[1].to_i
    case UNIT_LABELS.fetch(m[2].downcase)
    when "ans" then start >> (n * 12)
    when "mois" then start >> n
    else start + n
    end
  end

  def self.report(expired)
    puts
    puts error("⚠️  Droits de reproduction expirés (#{expired.size}) :")
    expired.each_with_index { |e, i| puts error("#{i + 1}. #{e[:title]} — expiré depuis le #{e[:expiry].iso8601}") }
    puts
  end
end
