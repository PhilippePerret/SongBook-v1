# frozen_string_literal: true

require_relative "../spec_helper"
require "tablator_assistant"
require "tmpdir"
require "fileutils"

# Machine à états de saisie clavier (Phil, 2026-08-26) : "0p2"/"0+2" (doigté droit +
# gauche) et "|"/"." (barres, ex. "|." fin du morceau) — y compris la collision de la
# touche "c" (doigté auriculaire pendant une note, sinon commande "config").
RSpec.describe "TablatorAssistant.write_tablature : composition clavier" do
  before do
    @song_dir = Dir.mktmpdir
    Session.song = @song_dir
    allow($stdin).to receive(:raw).and_yield
    allow($stdin).to receive(:winsize).and_return([24, 80])
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

  it "\"0p2\" : case 0, doigté droit \"p\", doigté gauche \"2\"" do
    script_keys("0", "p", "2", "\r")
    TablatorAssistant.write_tablature(title: "Test 0p2")
    expect(saved_body).to eq("10/8-p2")
  end

  it "\"0+2\" : \"+\" saute le doigté droit, ne garde que le gauche" do
    script_keys("0", "+", "2", "\r")
    TablatorAssistant.write_tablature(title: "Test 0+2")
    expect(saved_body).to eq("10/8-2")
  end

  it "\"0c\" pendant une note : \"c\" est le doigté auriculaire, PAS la commande config" do
    script_keys("0", "c", "\r")
    expect(TablatorAssistant).not_to receive(:open_config)
    TablatorAssistant.write_tablature(title: "Test 0c")
    expect(saved_body).to eq("10/8-c")
  end

  it "\"c\" SEUL (hors composition) reste la commande config" do
    script_keys("c", :up, :down, "\r") # ouvre/ferme le menu config, stubbé ci-dessous
    allow_any_instance_of(TTY::Prompt).to receive(:select).and_return(:unit)
    allow(TablatorAssistant).to receive(:choose_unit).and_return("croche")

    expect(TablatorAssistant).to receive(:open_config).and_call_original
    TablatorAssistant.write_tablature(title: "Test c seul")
  end

  it "\"|\" puis \".\" compose \"|.\" (fin du morceau), posée à la colonne courante" do
    script_keys("0", :right, "|", ".", "\r")
    TablatorAssistant.write_tablature(title: "Test bar")
    expect(saved_body).to eq("10/8 |.")
  end

  it "une frappe de barre invalide (ex. juste \":\") est abandonnée sans crash" do
    script_keys("0", :right, ":", :right, "\r")
    expect { TablatorAssistant.write_tablature(title: "Test bar invalide") }.not_to raise_error
    expect(saved_body).to eq("10/8")
  end

  it "une touche non gérée pendant la composition d'un doigté clôt la note telle quelle (partielle, valide)" do
    script_keys("0", "p", :right, "\r") # "p" posé, PAS de main gauche, flèche coupe la saisie
    TablatorAssistant.write_tablature(title: "Test partiel")
    expect(saved_body).to eq("10/8-p")
  end
end
