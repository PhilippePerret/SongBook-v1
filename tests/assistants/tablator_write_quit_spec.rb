# frozen_string_literal: true

require_relative "../spec_helper"
require "tablator_assistant"
require "tmpdir"
require "fileutils"

# `write_tablature` : "q" demande confirmation (bleu) avant d'enregistrer, cohérence
# avec les autres éditeurs de l'app ; Entrée enregistre directement, sans redemander
# . Message d'enregistrement : vert + "👍 ".
RSpec.describe "TablatorAssistant.write_tablature : sortie q vs Entrée" do
  # `before` (pas `around`) : le `before` GLOBAL de `spec_helper` (`Session.song = nil`
  # avant CHAQUE exemple) s'exécute APRÈS le début d'un `around` mais AVANT un `before`
  # LOCAL — fixer `Session.song` ici pour qu'il survive (leçon déjà tirée cette session).
  before do
    @song_dir = Dir.mktmpdir
    Session.song = @song_dir
    allow($stdin).to receive(:raw).and_yield
    allow($stdin).to receive(:winsize).and_return([24, 80])
  end
  after { FileUtils.rm_rf(@song_dir) }

  def script_keys(*seq)
    i = -1
    allow(TablatorAssistant).to receive(:read_key) do
      i += 1
      seq[i]
    end
  end

  def tab_files
    Dir.glob(File.join(@song_dir, "scores", "*.tab"))
  end

  it "\"q\" : confirmation refusée => RIEN enregistré" do
    script_keys("1", "q")
    allow_any_instance_of(TTY::Prompt).to receive(:yes?).and_return(false)

    TablatorAssistant.write_tablature(title: "Test Q Refuse")

    expect(tab_files).to be_empty
  end

  it "\"q\" : confirmation acceptée => enregistré, message vert 👍" do
    script_keys("1", "q")
    allow_any_instance_of(TTY::Prompt).to receive(:yes?).and_return(true)

    expect { TablatorAssistant.write_tablature(title: "Test Q Accepte") }
      .to output(/#{Regexp.escape(AnsiColors::SUCCESS)}👍/).to_stdout

    expect(tab_files.size).to eq(1)
  end

  it "Entrée : enregistre directement, MÊME si la question (stubbée) répondrait non" do
    script_keys("1", "\r")
    allow_any_instance_of(TTY::Prompt).to receive(:yes?).and_return(false)

    TablatorAssistant.write_tablature(title: "Test Entree")

    expect(tab_files.size).to eq(1)
  end
end
