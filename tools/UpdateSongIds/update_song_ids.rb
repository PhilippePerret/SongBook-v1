#!/usr/bin/env ruby
# frozen_string_literal: true

# Mise à jour interactive des identifiants de chanson vers `titre-performer-annee`
# (`CarnetBuilder.song_id`) : fiche `.infos`/`.inf` de la chanson et table des
# matières du carnet complet. Chaque changement est confirmé (accepter / modifier /
# passer).
#
# Usage : ruby tools/UpdateSongIds/update_song_ids.rb

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "app_config"
require "carnet_builder"
require "file_finder"
require "ansi_colors"

module UpdateSongIds
  extend AnsiColors

  FULL_CARNET = "Carnet-all"

  def self.proposals(songs_dir)
    Dir.children(songs_dir).sort.filter_map do |entry|
      folder = File.join(songs_dir, entry)
      next unless File.directory?(folder)

      infos_path = FileFinder.find(folder, :inf)
      next unless infos_path

      infos = CarnetBuilder.parse_nested_infos(infos_path)
      year = infos["year"].to_s.strip
      next if year.empty?

      new_id = CarnetBuilder.song_id(infos["title"].to_s, infos["performer"].to_s, year)
      old_id = infos["id"].to_s.strip
      next if new_id == old_id

      { folder: folder, infos_path: infos_path, title: infos["title"], performer: infos["performer"], old_id: old_id, new_id: new_id }
    end
  end

  # Remplace (ou ajoute en tête) la ligne `id:` de la fiche.
  def self.write_infos_id(infos_path, new_id)
    content = File.read(infos_path)
    content = content.match?(/^id:.*$/) ? content.sub(/^id:.*$/, "id: #{new_id}") : "id: #{new_id}\n#{content}"
    File.write(infos_path, content)
  end

  # Remplace la ligne `- <old_id>` de la table des matières. `false` si absente.
  def self.write_tdm_id(tdm_path, old_id, new_id)
    return false if old_id.empty? || !File.exist?(tdm_path)

    content = File.read(tdm_path)
    re = /^-\s*#{Regexp.escape(old_id)}[ \t]*$/
    return false unless content.match?(re)

    File.write(tdm_path, content.sub(re, "- #{new_id}"))
    true
  end

  def self.run
    tdm_path = FileFinder.find(File.join(AppConfig.songbooks_dir, FULL_CARNET), :tdm)
    abort "table des matières du carnet complet introuvable" unless tdm_path

    prompt = colored_prompt
    list = proposals(AppConfig.songs_dir)
    puts gray("#{list.size} identifiant(s) à revoir.")
    list.each_with_index do |p, i|
      puts
      puts yellow("[#{i + 1}/#{list.size}] #{p[:title]} — #{p[:performer]}")
      puts "  actuel  : #{p[:old_id]}"
      puts "  proposé : #{p[:new_id]}"
      choice = prompt.select("", [
        { name: "Accepter", value: :accept },
        { name: "Modifier", value: :edit },
        { name: "Passer", value: :skip },
        { name: "Arrêter", value: :stop },
      ], show_help: false)
      break if choice == :stop
      next if choice == :skip

      new_id = choice == :edit ? prompt.ask("Identifiant :", default: p[:new_id]) { |q| q.required true }.strip : p[:new_id]
      next if new_id == p[:old_id]

      write_infos_id(p[:infos_path], new_id)
      in_tdm = write_tdm_id(tdm_path, p[:old_id], new_id)
      puts success("  fiche mise à jour#{in_tdm ? ", carnet complet mis à jour" : ""}")
      puts gray("  (absent du carnet complet)") unless in_tdm
    end
  end
end

UpdateSongIds.run if $PROGRAM_NAME == __FILE__
