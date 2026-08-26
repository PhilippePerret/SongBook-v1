# frozen_string_literal: true

require_relative "../spec_helper"
require "cli"
require "session"
require "tablator_assistant"
require "tmpdir"
require "fileutils"

# Tests du mode interactif — commande `edit tab` (recherche PROGRESSIVE du nom, même
# convention que chanson/carnet — voir `TablatorAssistant.resolve_tab_path`).
RSpec.describe "commande edit tab" do
  # `before` (pas `around`) : le `before` GLOBAL de `spec_helper` (`Session.song = nil`
  # avant CHAQUE exemple) s'exécute entre le début d'un `around` et l'exemple lui-même —
  # y fixer `Session.song` ici, dans un `before` LOCAL, qui s'exécute APRÈS le global.
  before { @song_dir = Dir.mktmpdir; Session.song = @song_dir }
  after { FileUtils.rm_rf(@song_dir) }

  def write_tab(name)
    File.write(File.join(@song_dir, "#{name}.tab"), "# tab\n")
  end

  describe "TablatorAssistant.resolve_tab_path" do
    it "refuse sans chanson de contexte" do
      Session.song = nil
      expect { TablatorAssistant.resolve_tab_path("intro") }.to raise_error(SystemExit)
    end

    it "refuse si la chanson n'a aucune tablature" do
      expect { TablatorAssistant.resolve_tab_path("intro") }.to raise_error(SystemExit)
    end

    it "1 seule tablature qui correspond (préfixe) : reprise directement, sans question" do
      write_tab("intro-couplet")
      write_tab("solo-final")

      expect(TTY::Prompt).not_to receive(:new)
      expect(TablatorAssistant.resolve_tab_path("intro")).to eq(File.join(@song_dir, "intro-couplet.tab"))
    end

    it "plusieurs tablatures correspondent : demande de choisir parmi CES résultats" do
      write_tab("intro-couplet")
      write_tab("intro-refrain")
      write_tab("solo-final")

      allow_any_instance_of(TTY::Prompt).to receive(:select) do |_, _msg, choices, **|
        expect(choices.map { |c| c[:value] }.compact.size).to eq(2) # les 2 "intro-*", pas "solo-final"
        File.join(@song_dir, "intro-refrain.tab")
      end
      expect(TablatorAssistant.resolve_tab_path("intro")).to eq(File.join(@song_dir, "intro-refrain.tab"))
    end

    it "aucune correspondance directe : repli flou (\"vouliez-vous dire\")" do
      write_tab("introduction")

      allow_any_instance_of(TTY::Prompt).to receive(:select).and_return(File.join(@song_dir, "introduction.tab"))
      expect(TablatorAssistant.resolve_tab_path("introdction")).to eq(File.join(@song_dir, "introduction.tab"))
    end

    it "aucun nom donné : liste TOUTES les tablatures trouvées" do
      write_tab("intro-couplet")
      write_tab("solo-final")

      allow_any_instance_of(TTY::Prompt).to receive(:select) do |_, _msg, choices, **|
        expect(choices.map { |c| c[:value] }.compact.size).to eq(2)
        File.join(@song_dir, "solo-final.tab")
      end
      expect(TablatorAssistant.resolve_tab_path(nil)).to eq(File.join(@song_dir, "solo-final.tab"))
    end
  end

  describe "dispatch CLI" do
    it "'edit tab NOM' route vers write_tablature avec la tablature résolue" do
      write_tab("intro-couplet")
      tab_path = File.join(@song_dir, "intro-couplet.tab")

      expect(TablatorAssistant).to receive(:write_tablature).with(edit_path: tab_path)
      CLI.run(%w[edit tab intro], interactive: true)
    end

    it "'edit tab' sans argument propose la liste" do
      write_tab("intro-couplet")
      write_tab("solo-final")
      tab_path = File.join(@song_dir, "solo-final.tab")

      allow_any_instance_of(TTY::Prompt).to receive(:select).and_return(tab_path)
      expect(TablatorAssistant).to receive(:write_tablature).with(edit_path: tab_path)
      CLI.run(%w[edit tab], interactive: true)
    end
  end
end
