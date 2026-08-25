# frozen_string_literal: true

require_relative "../spec_helper"
require "song_cache"
require "fileutils"
require "tmpdir"

# Tests des outils
#
# Toujours un dossier temporaire À USAGE UNIQUE par test (jamais `FIXTURE_SONGS_DIR`) :
# `SongCache` garde un cache EN MÉMOIRE par dossier (`@caches`), un chemin partagé entre
# tests ferait fuiter l'état de l'un vers l'autre.
RSpec.describe "mémoire des chansons déjà rencontrées (cache)" do
  def make_song(dir, folder, infos)
    song_dir = File.join(dir, folder)
    FileUtils.mkdir_p(song_dir)
    File.write(File.join(song_dir, "c.lyr"), "Paroles\n")
    File.write(File.join(song_dir, "c.infos"), infos.map { |k, v| "#{k}: #{v}" }.join("\n"))
    song_dir
  end

  it "Retrouver une chanson déjà sur le disque, jamais encore mise en mémoire" do
    Dir.mktmpdir do |dir|
      make_song(dir, "Ma Chanson", { "title" => "Ma Chanson", "id" => "ma-chanson" })
      entry = SongCache.resolve(dir, "Ma Chanson")
      expect(entry[:folder]).to eq("Ma Chanson")
    end
  end

  it "Retrouver une chanson par son identifiant même si le dossier a un autre nom" do
    Dir.mktmpdir do |dir|
      make_song(dir, "dossier-bizarre", { "title" => "Vrai Titre", "id" => "identifiant-x" })
      entry = SongCache.resolve(dir, "identifiant-x")
      expect(entry[:folder]).to eq("dossier-bizarre")
    end
  end

  it "Créer la chanson automatiquement si elle n'existe nulle part" do
    Dir.mktmpdir do |dir|
      created = false
      entry = SongCache.resolve(dir, "Chanson Inconnue") do |_name|
        created = true
        song_dir = make_song(dir, "Chanson Inconnue", { "title" => "Chanson Inconnue", "id" => "chanson-inconnue" })
        { folder: File.basename(song_dir), infos: { "title" => "Chanson Inconnue" } }
      end
      expect(created).to be true
      expect(entry[:folder]).to eq("Chanson Inconnue")
    end
  end

  it "Dire qu'il n'y a rien si la chanson n'existe pas et qu'on ne demande pas de la créer" do
    Dir.mktmpdir do |dir|
      expect(SongCache.resolve(dir, "Personne Ici")).to be_nil
    end
  end

  it "Ne pas garder une chanson en mémoire si son dossier a disparu depuis" do
    Dir.mktmpdir do |dir|
      make_song(dir, "Chanson Temporaire", { "title" => "Chanson Temporaire", "id" => "chanson-temp" })
      first = SongCache.resolve(dir, "Chanson Temporaire")
      expect(first).not_to be_nil

      FileUtils.rm_rf(File.join(dir, "Chanson Temporaire"))

      expect(SongCache.resolve(dir, "chanson-temp")).to be_nil
    end
  end
end
