# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "yaml"
require "shellwords"
require_relative "app_config"
require_relative "carnet_builder"
require_relative "file_finder"
require_relative "icare_editions"
require_relative "printer_profile"

# Carnet de chant sur le site des éditions (`_sections_/carnets_chant/items/<id>/`) :
# `data.yaml`, `texte.md`, `tdm.yaml`, couverture et miniature.
module SongbookSite
  ITEMS_DIR = File.join(IcareEditions::EDITIONS_DIR, "_sections_", "carnets_chant", "items")
  RENDER_DPI = 400
  COVER_PPI = 300
  COVER_HEIGHT = 2000
  MINIATURE_HEIGHT = 300

  def self.folder_for(carnet_id, items_dir = ITEMS_DIR)
    File.join(items_dir, carnet_id)
  end

  # Crée le dossier du carnet. `:exists` si déjà là (rien touché), sinon `:created`.
  def self.create(carnet_folder, carnet_id, items_dir = ITEMS_DIR)
    folder = folder_for(carnet_id, items_dir)
    return :exists if Dir.exist?(folder)

    FileUtils.mkdir_p(folder)
    conf = carnet_conf(carnet_folder)
    data = {
      "id" => carnet_id,
      "title" => conf["title"].to_s,
      "subtitle" => (conf["subtitle"].is_a?(String) ? conf["subtitle"] : nil),
      "url" => nil,
      "prix" => conf["price"],
    }
    File.write(File.join(folder, "data.yaml"), data.to_yaml)
    File.write(File.join(folder, "texte.md"), "")
    write_tdm(carnet_folder, carnet_id, items_dir)
    :created
  end

  # `tdm.yaml` : `{ id:, titre: "Titre (Performer)" }` dans l'ordre du `.tdm` du carnet.
  # Ne fait rien si le carnet n'a pas de dossier sur le site.
  def self.write_tdm(carnet_folder, carnet_id, items_dir = ITEMS_DIR, songs_dir = AppConfig.songs_dir)
    folder = folder_for(carnet_id, items_dir)
    return false unless Dir.exist?(folder)

    songs = songs_by_id(songs_dir)
    entries = tdm_ids(carnet_folder).map do |id|
      infos = songs[id] || {}
      titre = infos["title"] ? "#{infos["title"]} (#{infos["performer"]})" : id
      { "id" => id, "titre" => titre }
    end
    File.write(File.join(folder, "tdm.yaml"), entries.to_yaml)
    true
  end

  # Ids des chansons du `.tdm` du carnet, dans l'ordre.
  def self.tdm_ids(carnet_folder)
    tdm_path = FileFinder.find(carnet_folder, :tdm)
    tdm_path ? File.read(tdm_path).scan(/^-\s*(\S+)/).flatten : []
  end

  def self.songs_by_id(songs_dir)
    song_folders_by_id(songs_dir).transform_values { |folder| CarnetBuilder.parse_nested_infos(FileFinder.find(folder, :inf)) }
  end

  def self.song_folders_by_id(songs_dir = AppConfig.songs_dir)
    Dir.children(songs_dir).each_with_object({}) do |entry, h|
      folder = File.join(songs_dir, entry)
      next unless File.directory?(folder)

      infos_path = FileFinder.find(folder, :inf)
      next unless infos_path

      id = CarnetBuilder.parse_nested_infos(infos_path)["id"].to_s
      h[id] = folder unless id.empty?
    end
  end

  def self.covers_exist?(carnet_id, items_dir = ITEMS_DIR)
    folder = folder_for(carnet_id, items_dir)
    %w[cover.png miniature.png].all? { |name| File.exist?(File.join(folder, name)) }
  end

  # PDF de couverture de la dernière version du carnet (`export/cover/*-v<n>-cover.pdf`).
  def self.latest_cover_pdf(carnet_folder)
    Dir.glob(File.join(carnet_folder, "export", "cover", "*.pdf")).max_by { |f| f[/-v(\d+)-cover\.pdf\z/, 1].to_i }
  end

  # `cover.png` (~2000 px de haut) et `miniature.png` (300 px de haut), 300 ppi,
  # transparence gardée, tirés du PDF de couverture (4e + dos + 1re) : moitié droite,
  # moins la demi-épaisseur approximative du dos (nombre de pages du dernier carnet
  # construit) et le fond perdu. Précision inutile ici. Renvoie `:no_pdf`, `:failed`
  # ou `:created`.
  def self.make_covers(carnet_folder, carnet_id, items_dir = ITEMS_DIR)
    pdf = latest_cover_pdf(carnet_folder)
    return :no_pdf unless pdf

    folder = folder_for(carnet_id, items_dir)
    FileUtils.mkdir_p(folder)
    Dir.mktmpdir do |tmp|
      full = File.join(tmp, "full.png")
      return :failed unless system("mutool", "draw", "-q", "-r", RENDER_DPI.to_s, "-c", "rgba", "-o", full, pdf, "1", out: File::NULL, err: File::NULL)

      width, height = `magick identify -format "%w %h" #{full.shellescape}`.split.map(&:to_i)
      bleed = (PrinterProfile::BLEED_IN * RENDER_DPI).round
      half_spine = (spine_width(carnet_folder) / 2 * RENDER_DPI).round
      x0 = width / 2 + half_spine
      crop = "#{width - bleed - x0}x#{height - 2 * bleed}+#{x0}+#{bleed}"
      ppi = ["-units", "PixelsPerInch", "-density", COVER_PPI.to_s]
      cover = File.join(folder, "cover.png")
      ok = system("magick", full, "-crop", crop, "+repage", "-resize", "x#{COVER_HEIGHT}", *ppi, cover) &&
           system("magick", cover, "-resize", "x#{MINIATURE_HEIGHT}", *ppi, File.join(folder, "miniature.png"))
      ok ? :created : :failed
    end
  end

  # Épaisseur approximative du dos (pouces) — 0 si le carnet n'a jamais été construit.
  def self.spine_width(carnet_folder)
    require_relative "cli"
    stderr = $stderr
    $stderr = File.open(File::NULL, "w")
    CLI.printer_for_carnet(carnet_folder).spine_width
  rescue SystemExit
    0.0
  ensure
    $stderr = stderr
  end

  def self.carnet_conf(carnet_folder)
    infos_path = FileFinder.find(carnet_folder, :inf)
    infos_path ? CarnetBuilder.parse_nested_infos(infos_path) : {}
  end
end
