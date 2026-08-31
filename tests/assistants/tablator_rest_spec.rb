# frozen_string_literal: true

require_relative "../spec_helper"
require "tablator_assistant"
require "tmpdir"
require "fileutils"

# Silence explicite ("r" visible, "s" invisible) : posé comme une
# note, la position de l'événement suivant détermine sa durée. "s" minuscule est
# libéré pour ce sens ("s SVG sans quitter" passe à "S" majuscule, même principe que
# "B" pour barre : une lettre à plat ne porte qu'un seul sens).
RSpec.describe "TablatorAssistant : silences explicites (r/s)" do
  before do
    @song_dir = Dir.mktmpdir
    Session.song = @song_dir
    allow($stdin).to receive(:raw).and_yield
    allow($stdin).to receive(:winsize).and_return([24, 13]) # grille étroite, 5 colonnes
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

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  it "\"r\" pose un silence VISIBLE, borné par la note suivante" do
    script_keys("5", :right, "r", "\r")
    TablatorAssistant.write_tablature(title: "Test r")

    expect(saved_body).to eq("15/8 r2")
  end

  it "\"s\" pose un silence INVISIBLE, même logique" do
    script_keys("5", :right, "s", "\r")
    TablatorAssistant.write_tablature(title: "Test s")

    expect(saved_body).to eq("15/8 s2")
  end

  it "\"x\" retire un silence explicite posé" do
    script_keys("5", :right, "r", "x", "\r")
    TablatorAssistant.write_tablature(title: "Test x retire silence")

    expect(saved_body).to eq("15/8")
  end

  it "poser une note sur une colonne où était un silence l'efface" do
    script_keys("5", :right, "r", "3", "\r")
    TablatorAssistant.write_tablature(title: "Test note écrase silence")

    expect(saved_body).to eq("15/8 13/2")
  end

  it "\"S\" (majuscule) produit le SVG sans quitter, ne pose PAS de silence" do
    script_keys("5", "S", "\r")
    printed = capture_stdout { TablatorAssistant.write_tablature(title: "Test S SVG") }

    expect(printed).to include("Fichier SVG produit")
    expect(saved_body).to eq("15/8")
  end
end
