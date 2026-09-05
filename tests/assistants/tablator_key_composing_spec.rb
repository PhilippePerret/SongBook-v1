# frozen_string_literal: true

require_relative "../spec_helper"
require "tablator_assistant"
require "tmpdir"
require "fileutils"

# Machine à états de saisie clavier  : "0p2"/"0+2" (doigté droit +
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

  describe "\"h\"/\"p\"/\"g\" (hammer-on/pull-off/slide, issue #39)" do
    it "\"g\" puis un chiffre sur une case VIDE : amorce une nouvelle note liée" do
      script_keys("g", "5", "\r")
      TablatorAssistant.write_tablature(title: "Test slide neuf")
      expect(saved_body).to eq("g15/8")
    end

    it "bug constaté : \"g\" posé sur une note DÉJÀ existante (revenir la marquer après coup) ne doit PAS effacer sa case" do
      script_keys("7", :right, "3", :left, "g", "\r") # note 7 (col 0), note 3 (col 1), retour col 0, marquée "g" après coup
      TablatorAssistant.write_tablature(title: "Test slide retroactif")
      expect(saved_body).to eq("g17/8 13/8")
    end

    it "bug constaté : retaper un chiffre sur une note qui a DÉJÀ un lien ne doit PAS l'effacer" do
      script_keys("g", "6", :right, "3", :left, "8", "\r") # "g6" (col 0), note 3 (col 1), retour col 0, retape "8" (correction de case)
      TablatorAssistant.write_tablature(title: "Test slide corrige")
      expect(saved_body).to eq("g18/8 13/8")
    end

    it "bug constaté (réel, \"Some Devil\"/acc.tab) : un ACCORD ENTIER qui glisse (\"g\" posé APRÈS COUP sur une seule de ses notes) ne doit pas perdre son lien à l'enregistrement" do
      # col 0 : accord <34 45> (corde3 case4, corde4 case5). col 1 : accord <36 47>
      # (corde3 case6, corde4 case7), marqué "g" sur la corde3 SEULEMENT — une fois la
      # composition de cette cellule terminée (aller-retour col1<->col0), pas pendant
      # (sinon "g" ne fait rien, voir tests ci-dessus : la garde exige de ne PAS être en
      # train de composer CETTE cellule précise).
      script_keys(:down, :down, "4", :down, "5", :right, "7", :up, "6", :left, :right, "g", "\r")
      TablatorAssistant.write_tablature(title: "Test accord slide")
      expect(saved_body).to eq("<34 45>/8 g<36 47>/8")
    end
  end
end
