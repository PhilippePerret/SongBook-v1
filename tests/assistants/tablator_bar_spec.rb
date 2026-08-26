# frozen_string_literal: true

require_relative "../spec_helper"
require "tablator_assistant"
require "tmpdir"
require "fileutils"

# Une barre traverse TOUTE la tablature (Phil, 2026-08-27) : dessinée sur les 6 cordes,
# retirable avec un simple "x" depuis N'IMPORTE QUELLE corde à sa colonne.
RSpec.describe "TablatorAssistant : barres" do
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

  it "\"x\" retire une barre depuis une AUTRE corde que celle utilisée pour la poser" do
    # Note en colonne 0 (corde 1), puis colonne 1 : pose "|", descend à la corde 6
    # (5x :down, la colonne ne bouge pas), x — la barre doit disparaître.
    script_keys("0", :right, "|", :down, :down, :down, :down, :down, "x", "\r")
    TablatorAssistant.write_tablature(title: "Test x retire barre")

    expect(saved_body).to eq("10/8")
  end

  it "une barre est dessinée sur les 6 cordes (pas seulement une ligne à part)" do
    # ":down" (touche neutre) clôt la composition de la barre AVANT le dernier rendu
    # affiché à l'écran (celui juste avant "\r"), pour pouvoir vérifier son affichage.
    script_keys("0", :right, "|", :down, "\r")

    printed = capture_stdout { TablatorAssistant.write_tablature(title: "Test rendu barre") }
    last_frame = printed.split("\e[2J\e[H").last
    lines = last_frame.lines.grep(/\A[A-Ga-g]\|/)

    expect(lines.size).to eq(6)
    expect(lines).to all(include("| ")) # "|" (colonne de la barre, remplie d'espace) sur les 6 lignes de cordes
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end
end
