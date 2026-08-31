# frozen_string_literal: true

require_relative "../spec_helper"
require "tablator_assistant"
require "tmpdir"
require "fileutils"

# "J"/"L" (début/fin de la tablature) : mêmes lettres que "début/fin de vers" dans
# l'édition des accords (`ChordPlacer`).
RSpec.describe "TablatorAssistant.write_tablature : navigation J/L" do
  before do
    @song_dir = Dir.mktmpdir
    Session.song = @song_dir
    allow($stdin).to receive(:raw).and_yield
    # winsize -> largeur de grille = 5 colonnes (0..4), petite et prévisible pour le test.
    allow($stdin).to receive(:winsize).and_return([24, 13])
    allow_any_instance_of(TTY::Prompt).to receive(:yes?).and_return(true)
  end
  after { FileUtils.rm_rf(@song_dir) }

  def script_keys(*seq)
    i = -1
    allow(TablatorAssistant).to receive(:read_key) do
      i += 1
      seq[i]
    end
  end

  def saved_body
    path = Dir.glob(File.join(@song_dir, "scores", "*.tab")).first
    _, body = Tablator.parse_frontmatter(File.read(path))
    body.strip
  end

  it "\"J\" ramène au DÉBUT (colonne 0), quelle que soit la position courante" do
    script_keys(:right, :right, :right, "J", "5", "\r")
    TablatorAssistant.write_tablature(title: "Test J")
    apres_j = saved_body

    script_keys("5", "\r") # note posée directement en colonne 0, sans déplacement
    TablatorAssistant.write_tablature(title: "Test J baseline")

    expect(apres_j).to eq(saved_body)
  end

  it "\"L\" va à la fin de la portion ÉCRITE, pas au bout de la grille" do
    # Note posée en colonne 2 (2x :right), puis retour au début (J), puis "L" :
    # doit revenir en colonne 2 (dernière colonne écrite), pas en colonne 4
    # (dernière colonne de la grille, largeur 5).
    script_keys(:right, :right, "5", "J", "L", :down, "3", "\r")
    TablatorAssistant.write_tablature(title: "Test L")
    apres_l = saved_body

    script_keys(:right, :right, "5", :down, "3", "\r") # note posée directement en colonne 2
    TablatorAssistant.write_tablature(title: "Test L baseline")

    expect(apres_l).to eq(saved_body)
  end

  it "\"L\" sur une grille vide reste en colonne 0 (rien d'écrit à rejoindre)" do
    script_keys("L", "5", "\r")
    TablatorAssistant.write_tablature(title: "Test L vide")
    apres_l = saved_body

    script_keys("5", "\r") # note posée directement en colonne 0, sans déplacement
    TablatorAssistant.write_tablature(title: "Test L vide baseline")

    expect(apres_l).to eq(saved_body)
  end
end
