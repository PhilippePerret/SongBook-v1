# frozen_string_literal: true

require_relative "../spec_helper"
require "cli"
require "session"
require "file_finder"
require "fileutils"

# `edit lyrics/lyr`, `edit infos/inf`, `edit gabarit/gab` : alias de `open lyrics/lyr`,
# `open infos/inf`, `open gabarit/gab` (Phil, 2026-08-28) — même comportement, mêmes
# abréviations, sans dupliquer la logique (voir `CLI.open_lyrics_file`/`open_infos_file`/
# `open_gabarit_file`, partagées entre les deux commandes).
RSpec.describe "commande edit : alias de open (lyrics/infos/gabarit)" do
  let(:song_export) { File.join(FIXTURE_SONGS_DIR, "Angie", "export") }
  let(:carnet_export) { File.join(FIXTURE_SONGBOOKS_DIR, "Carnet-Test", "export") }

  after do
    FileUtils.rm_rf(song_export)
    FileUtils.rm_rf(carnet_export)
  end

  describe "'edit lyrics'/'edit lyr'" do
    it "ouvre le .lyr de la chanson en contexte, comme 'open lyrics'" do
      CLI.run(%w[use song Angie], interactive: true)
      lyr_path = FileFinder.find(Session.song, :lyr)

      expect(CLI).to receive(:system).with("open", "-a", AppConfig.user_song_editor, lyr_path)
      CLI.run(%w[edit lyrics], interactive: true)
    end

    it "l'abréviation 'lyr' fonctionne aussi" do
      CLI.run(%w[use song Angie], interactive: true)
      lyr_path = FileFinder.find(Session.song, :lyr)

      expect(CLI).to receive(:system).with("open", "-a", AppConfig.user_song_editor, lyr_path)
      CLI.run(%w[edit lyr], interactive: true)
    end
  end

  describe "'edit infos'/'edit inf'" do
    it "ouvre le .infos de la chanson en contexte, comme 'open infos'" do
      CLI.run(%w[use song Angie], interactive: true)
      inf_path = FileFinder.find(Session.song, :inf)

      expect(CLI).to receive(:system).with("open", "-a", AppConfig.user_song_editor, inf_path)
      CLI.run(%w[edit infos], interactive: true)
    end

    it "l'abréviation 'inf' fonctionne aussi" do
      CLI.run(%w[use song Angie], interactive: true)
      inf_path = FileFinder.find(Session.song, :inf)

      expect(CLI).to receive(:system).with("open", "-a", AppConfig.user_song_editor, inf_path)
      CLI.run(%w[edit inf], interactive: true)
    end
  end

  describe "'edit gabarit'/'edit gab'" do
    it "ouvre le .gab de la chanson en contexte, comme 'open gabarit'" do
      CLI.run(%w[use song Angie], interactive: true)
      gab_path = FileFinder.find(Session.song, :gab)

      expect(CLI).to receive(:system).with("open", "-a", AppConfig.user_song_editor, gab_path)
      CLI.run(%w[edit gabarit], interactive: true)
    end

    it "l'abréviation 'gab' fonctionne aussi" do
      CLI.run(%w[use song Angie], interactive: true)
      gab_path = FileFinder.find(Session.song, :gab)

      expect(CLI).to receive(:system).with("open", "-a", AppConfig.user_song_editor, gab_path)
      CLI.run(%w[edit gab], interactive: true)
    end
  end
end
