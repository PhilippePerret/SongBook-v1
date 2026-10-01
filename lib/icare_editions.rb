# frozen_string_literal: true

require "fileutils"
require "pty"
require "yaml"
require_relative "carnet_builder"
require_relative "file_finder"

# Site des éditions Icare : dossier d'une chanson dans les items de la section
# "chansons" (`songbook ie create song`).
module IcareEditions
  EDITIONS_DIR = "/Users/philippeperret/Sites/Atelier_Icare/Icare_2025/icare_editions_dev"
  SONGS_ITEMS_DIR = File.join(EDITIONS_DIR, "_sections_", "chansons", "items")
  SONG_PAGE_URL = "https://icare-editions.fr/?s=ch&i=%s"

  # Crée `<SONGS_ITEMS_DIR>/<id>/` avec `texte.md` (vide) et `data.yaml` (id, title,
  # performer, carnets vide). Renvoie `{ status:, folder: }` — `:created`, `:exists`
  # (dossier déjà là, rien touché) ou `:no_id` (fiche sans `id`).
  def self.create_song_item(song_folder, items_dir = SONGS_ITEMS_DIR)
    infos_path = FileFinder.find(song_folder, :inf)
    infos = infos_path ? CarnetBuilder.parse_nested_infos(infos_path) : {}
    id = infos["id"].to_s.strip
    return { status: :no_id, folder: nil } if id.empty?

    folder = File.join(items_dir, id)
    return { status: :exists, folder: folder } if Dir.exist?(folder)

    FileUtils.mkdir_p(folder)
    File.write(File.join(folder, "texte.md"), "")
    data = {
      "id" => id,
      "title" => infos["title"].to_s,
      "performer" => infos["performer"].to_s,
      "carnets" => [],
    }
    File.write(File.join(folder, "data.yaml"), data.to_yaml)
    { status: :created, folder: folder }
  end

  # Ajoute `carnet_id` à la donnée `carnets` du `data.yaml` (autres données conservées).
  # `false` s'il y est déjà.
  def self.add_carnet(item_folder, carnet_id)
    path = File.join(item_folder, "data.yaml")
    data = YAML.safe_load_file(path) || {}
    carnets = Array(data["carnets"])
    return false if carnets.include?(carnet_id)

    data["carnets"] = carnets + [carnet_id]
    File.write(path, data.to_yaml)
    true
  end

  SYNC_QUESTION = "Dois-je uploader"

  # Joue `./sync.rb` du site (copie dev -> prod locale puis envoi en ligne), sortie
  # affichée telle quelle, question d'envoi en ligne confirmée d'office.
  def self.sync
    answered = false
    buffer = +""
    PTY.spawn("./sync.rb", chdir: EDITIONS_DIR) do |reader, writer, pid|
      begin
        loop do
          chunk = reader.readpartial(4096)
          $stdout.write(chunk)
          $stdout.flush
          next if answered

          buffer << chunk
          next unless buffer.include?(SYNC_QUESTION)

          sleep 0.3
          writer.write("y")
          sleep 0.1
          writer.write("\r")
          answered = true
        end
      rescue EOFError, Errno::EIO
        nil
      end
      Process.wait(pid)
    end
    $?.success?
  end
end
