# frozen_string_literal: true

require_relative "../spec_helper"
require "cli"
require "session"
require "file_finder"
require "fileutils"

# Tests du mode interactif — commande `open`
RSpec.describe "commande open" do
  let(:song_export) { File.join(FIXTURE_SONGS_DIR, "Angie", "export") }
  let(:carnet_export) { File.join(FIXTURE_SONGBOOKS_DIR, "Carnet-Test", "export") }

  after do
    FileUtils.rm_rf(song_export)
    FileUtils.rm_rf(carnet_export)
  end

  describe "'open' bare (bug 2026-08-26 : 'commande inconnue' après use song + build)" do
    it "route vers le même comportement que 'open song' (pas d'erreur 'commande inconnue')" do
      CLI.run(%w[use song Angie], interactive: true)
      allow_any_instance_of(TTY::Prompt).to receive(:multi_select).and_return([])

      expect { CLI.run(%w[open], interactive: true) }.not_to raise_error
    end

    it "'open song' explicite continue de fonctionner (inchangé)" do
      CLI.run(%w[use song Angie], interactive: true)
      allow_any_instance_of(TTY::Prompt).to receive(:multi_select).and_return([])

      expect { CLI.run(%w[open song], interactive: true) }.not_to raise_error
    end
  end

  describe "'open folder'" do
    it "ouvre le dossier de la chanson en contexte (priorité sur le carnet)" do
      CLI.run(%w[use songbook Carnet-Test], interactive: true)
      CLI.run(%w[use song Angie], interactive: true)

      expect(SongCreator).to receive(:open_in_file_manager).with(Session.song)
      CLI.run(%w[open folder], interactive: true)
    end

    it "retombe sur le dossier du carnet si aucune chanson en contexte" do
      CLI.run(%w[use songbook Carnet-Test], interactive: true)

      expect(SongCreator).to receive(:open_in_file_manager).with(Session.carnet)
      CLI.run(%w[open folder], interactive: true)
    end

    it "refuse sans aucun contexte" do
      expect { CLI.run(%w[open folder], interactive: true) }.to raise_error(SystemExit)
    end
  end

  describe "'open lyrics'" do
    it "ouvre le .lyr de la chanson en contexte" do
      CLI.run(%w[use song Angie], interactive: true)
      lyr_path = FileFinder.find(Session.song, :lyr)

      expect(CLI).to receive(:system).with("open", "-a", AppConfig.user_song_editor, lyr_path)
      CLI.run(%w[open lyrics], interactive: true)
    end

    it "refuse si seul un carnet est en contexte (n'existe que pour les chansons)" do
      CLI.run(%w[use songbook Carnet-Test], interactive: true)

      expect { CLI.run(%w[open lyrics], interactive: true) }.to raise_error(SystemExit)
    end
  end

  describe "'open infos'" do
    it "ouvre le .infos de la chanson en contexte" do
      CLI.run(%w[use song Angie], interactive: true)
      inf_path = FileFinder.find(Session.song, :inf)

      expect(CLI).to receive(:system).with("open", "-a", AppConfig.user_song_editor, inf_path)
      CLI.run(%w[open infos], interactive: true)
    end

    it "ouvre le .infos du carnet en contexte (pas de chanson sélectionnée)" do
      CLI.run(%w[use songbook Carnet-Test], interactive: true)
      inf_path = FileFinder.find(Session.carnet, :inf)

      expect(CLI).to receive(:system).with("open", "-a", AppConfig.user_song_editor, inf_path)
      CLI.run(%w[open infos], interactive: true)
    end
  end

  describe "'open gabarit'" do
    it "ouvre le .gab de la chanson en contexte" do
      CLI.run(%w[use song Angie], interactive: true)
      gab_path = FileFinder.find(Session.song, :gab)

      expect(CLI).to receive(:system).with("open", "-a", AppConfig.user_song_editor, gab_path)
      CLI.run(%w[open gabarit], interactive: true)
    end

    it "refuse si le contexte n'a pas de .gab (carnet sans gabarit)" do
      CLI.run(%w[use songbook Carnet-Test], interactive: true)

      expect { CLI.run(%w[open gabarit], interactive: true) }.to raise_error(SystemExit)
    end
  end

  describe "'open pdf'" do
    it "refuse si rien n'a encore été construit" do
      CLI.run(%w[use song Angie], interactive: true)

      expect { CLI.run(%w[open pdf], interactive: true) }.to raise_error(SystemExit)
    end

    it "ouvre le PDF déjà construit d'une chanson" do
      CLI.run(%w[use song Angie], interactive: true)
      out_path = CarnetBuilder.build_song(Session.song)

      expect(CLI).to receive(:system).with("open", out_path)
      CLI.run(%w[open pdf], interactive: true)
    end
  end

  describe "'open bidule' (sous-commande inconnue)" do
    it "reste une commande inconnue" do
      expect { CLI.run(%w[open bidule], interactive: true) }.to raise_error(SystemExit)
    end
  end
end
