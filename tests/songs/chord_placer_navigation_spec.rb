# frozen_string_literal: true

require_relative "../spec_helper"
require "chord_placer"
require "chord_line"
require "stringio"
require "tmpdir"

RSpec.describe "navigation et saisie d'accords (assistant d'accords)" do
  def key(mods = {})
    { mods: mods }
  end

  describe "ChordPlacer.move_horizontal (flèches ← →)" do
    let(:chord_lines) { { 0 => ChordLine.new("bonjour tout"), 1 => ChordLine.new("le monde") } }
    let(:editable) { [0, 1] }

    it "flèche nue avance de syllabe en syllabe" do
      pos, cursor = ChordPlacer.move_horizontal(key, 0, 0, chord_lines, editable, 1)
      expect(pos).to eq(0)
      expect(cursor).to be_between(1, chord_lines[0].text.length - 1)
    end

    it "flèche nue en butée de fin de vers saute au vers suivant (remplace l'ancien N)" do
      fin = chord_lines[0].text.length
      pos, cursor = ChordPlacer.move_horizontal(key, 0, fin, chord_lines, editable, 1)
      expect(pos).to eq(1)
      expect(cursor).to eq(0)
    end

    it "flèche nue en butée de début de vers saute au vers précédent (remplace l'ancien P)" do
      pos, cursor = ChordPlacer.move_horizontal(key, 1, 0, chord_lines, editable, -1)
      expect(pos).to eq(0)
      expect(cursor).to eq(chord_lines[0].text.length)
    end

    it "Alt+flèche ne fait plus rien de spécial (abandonné, intercepté par le terminal) : reste une syllabe" do
      pos, cursor = ChordPlacer.move_horizontal(key(alt: true), 0, 0, chord_lines, editable, 1)
      expect(pos).to eq(0)
      expect(cursor).to be_between(1, chord_lines[0].text.length - 1)
    end

    it "Shift+flèche décale le texte, inchangé" do
      pos, cursor = ChordPlacer.move_horizontal(key(shift: true), 0, 2, chord_lines, editable, 1)
      expect(pos).to eq(0)
      expect(chord_lines[0].text[0...2]).to eq("bo")
      expect(chord_lines[0].text[2]).to eq(" ")
      expect(cursor).to eq(3)
    end
  end

  describe "ChordPlacer.move_vertical (flèches ↑ ↓, pages fixes)" do
    let(:chord_lines) { (0..5).to_h { |i| [i, ChordLine.new("x" * (i + 1))] } }
    let(:editable) { (0..5).to_a } # WINDOW_SIZE = 4 => pages [0-3] puis [4-5]

    it "descend dans la même page : curseur borné à la longueur du nouveau vers" do
      pos, cursor = ChordPlacer.move_vertical(0, 5, chord_lines, editable, 1)
      expect(pos).to eq(1)
      expect(cursor).to eq(2)
    end

    it "franchit une page : curseur remis à 0" do
      pos, cursor = ChordPlacer.move_vertical(3, 2, chord_lines, editable, 1)
      expect(pos).to eq(4)
      expect(cursor).to eq(0)
    end

    it "ne descend pas au-delà du dernier vers" do
      pos, cursor = ChordPlacer.move_vertical(5, 0, chord_lines, editable, 1)
      expect(pos).to eq(5)
    end
  end

  describe "ChordPlacer.chord_known? (accord simple vs accord précis \"Nom-Case\")" do
    it "accord simple (pas de \"-\") : trouvé si N'IMPORTE QUELLE case existe" do
      expect(ChordPlacer.chord_known?("F7M", Dir.mktmpdir)).to be true
    end

    it "accord précis (\"Nom-Case\") : trouvé SEULEMENT si CETTE case exacte existe (bug 2026-08-26 : cherchait \"Nom-Case-*.svg\")" do
      expect(ChordPlacer.chord_known?("F7M-1", Dir.mktmpdir)).to be true
    end

    it "accord précis avec une case qui n'existe pas : PAS de repli sur une autre case" do
      expect(ChordPlacer.chord_known?("F7M-9", Dir.mktmpdir)).to be false
    end

    it "accord totalement inconnu : ni simple ni précis" do
      expect(ChordPlacer.chord_known?("Zzz9", Dir.mktmpdir)).to be false
    end
  end

  describe "ChordPlacer.typed_match (accord existant vs nouvel accord, refait à chaque frappe)" do
    it "minuscule initiale, correspond à un accord connu => ce nom exact" do
      expect(ChordPlacer.typed_match("a", { "a" => ["A"] })).to eq("A")
    end

    it "minuscule initiale, ne correspond à rien de connu => nil (nouvel accord)" do
      expect(ChordPlacer.typed_match("d", {})).to be_nil
    end

    it "MAJUSCULE initiale => jamais de correspondance, même si ça matcherait en minuscule" do
      expect(ChordPlacer.typed_match("A", { "a" => ["A"] })).to be_nil
    end

    it "se raffine à chaque caractère : 'f' matche 'F', 'f7' ne matche plus rien" do
      letters = { "f" => ["F"] }
      expect(ChordPlacer.typed_match("f", letters)).to eq("F")
      expect(ChordPlacer.typed_match("f7", letters)).to be_nil
    end

    it "'f7' matche si 'F7' est déjà connu de cette lettre" do
      letters = { "f" => %w[F F7] }
      expect(ChordPlacer.typed_match("f7", letters)).to eq("F7")
    end

    it "1 SEULE lettre = raccourci immédiat même si le nom de l'accord fait plusieurs caractères (bug 2026-08-26 : 'b' -> 'Bdim' n'écrivait plus rien, exigeait un match EXACT)" do
      expect(ChordPlacer.typed_match("b", { "b" => ["Bdim"] })).to eq("Bdim")
    end

    it "1 seule lettre : reprend le PREMIER accord de cette lettre (ordre de rencontre)" do
      expect(ChordPlacer.typed_match("a", { "a" => %w[Am7 A A7] })).to eq("Am7")
    end

    it "'b2' = 2e accord de la lettre 'b' par INDEX (légende 'b2 = ...', bug 2026-08-26 : laissé tel quel)" do
      expect(ChordPlacer.typed_match("b2", { "b" => %w[Bdim Bm9b] })).to eq("Bm9b")
    end

    it "'b9' = index hors bucket => nil (nouvel accord)" do
      expect(ChordPlacer.typed_match("b9", { "b" => %w[Bdim Bm9b] })).to be_nil
    end

    it "l'INDEX gagne même si un accord inutilisé porte littéralement le nom tapé (bug 2026-08-27 : un résidu 'B2' en cache volait le raccourci de position 'b2')" do
      letters = { "b" => %w[B7dim[d]-5 Bdim Bb Bbm B7dim B Bc B2 B3] }
      expect(ChordPlacer.typed_match("b2", letters)).to eq("Bdim")
    end
  end

  describe "ChordPlacer.active_letters (légende affichée = accords ACTIVEMENT posés, Phil 2026-08-26)" do
    it "retire un accord qui n'est plus posé nulle part (bug constaté : restait affiché après suppression)" do
      chord_lines = { 0 => ChordLine.new("bonjour", { 0 => "A" }) }
      letters = { "a" => ["A"], "d" => ["D"] } # "D" jamais posé dans chord_lines
      expect(ChordPlacer.active_letters(letters, chord_lines)).to eq({ "a" => ["A"] })
    end

    it "garde seulement les accords, d'une même lettre, RÉELLEMENT posés" do
      chord_lines = { 0 => ChordLine.new("bonjour tout", { 0 => "A", 8 => "Am7" }) }
      letters = { "a" => %w[A Am7 A7] } # "A7" connu mais jamais posé
      expect(ChordPlacer.active_letters(letters, chord_lines)).to eq({ "a" => %w[A Am7] })
    end

    it "aucun accord posé nulle part : légende vide" do
      chord_lines = { 0 => ChordLine.new("bonjour", {}) }
      letters = { "a" => ["A"] }
      expect(ChordPlacer.active_letters(letters, chord_lines)).to eq({})
    end
  end

  describe "ChordPlacer.normalize_digit (un chiffre est un chiffre, Phil 2026-08-26)" do
    it "chiffre du haut du clavier => lui-même" do
      expect(ChordPlacer.normalize_digit("7")).to eq("7")
    end

    it "pavé numérique (DECKPAM, symboles :kp0..:kp9) => chiffre correspondant" do
      expect(ChordPlacer.normalize_digit(:kp7)).to eq("7")
      expect(ChordPlacer.normalize_digit(:kp0)).to eq("0")
    end

    it "rangée du haut AZERTY sans Maj => chiffre correspondant" do
      expect(ChordPlacer.normalize_digit("&")).to eq("1")
      expect(ChordPlacer.normalize_digit("é")).to eq("2")
      expect(ChordPlacer.normalize_digit("à")).to eq("0")
    end

    it "pas un chiffre, sous aucune forme => nil" do
      expect(ChordPlacer.normalize_digit("a")).to be_nil
      expect(ChordPlacer.normalize_digit(:enter)).to be_nil
    end
  end

  describe "ChordPlacer.run (clavier simulé, terminal brut stubbé)" do
    around do |example|
      Dir.mktmpdir { |dir| @song_dir = dir; example.run }
    end

    def write_lyr(lines)
      path = File.join(@song_dir, "chanson.lyr")
      File.write(path, "#{lines.join("\n")}\n")
      path
    end

    def simulate(path, input, confirm: true)
      original_stdin = $stdin
      original_stdout = $stdout
      $stdin = StringIO.new(input)
      $stdout = StringIO.new
      allow(ChordPlacer).to receive(:with_raw_terminal).and_yield
      allow_any_instance_of(TTY::Prompt).to receive(:yes?).and_return(confirm)
      ChordPlacer.run(path)
    ensure
      $stdin = original_stdin
      $stdout = original_stdout
    end

    it "J ramène le curseur en tête du vers courant (remplace l'ancien raccourci A)" do
      path = write_lyr(["bonjour tout", "le monde"])
      # "\n" saute la question des accords initiaux (aucun connu) ; flèche droite
      # (déplace le curseur) ; J (retour en tête) ; "A" (nouvel accord) ; Entrée (valide
      # l'accord) ; Entrée (quitte l'assistant).
      simulate(path, "\n\e[CJA\r\r")
      expect(File.readlines(path).first.chomp).to eq("/A:bonjour tout")
    end

    it "L ramène le curseur en fin du vers courant (remplace l'ancien raccourci Z)" do
      path = write_lyr(["bonjour tout", "le monde"])
      simulate(path, "\nLG\r\r")
      expect(File.readlines(path).first.chomp).to eq("bonjour tout/G:")
    end

    it "une MAJUSCULE force un nouvel accord malgré la collision avec un raccourci connu" do
      path = write_lyr(["/Am7:bonjour tout"])
      # "a" déjà enregistré (Am7, lu depuis le fichier) => pas de question initiale.
      simulate(path, "LA\r\r")
      expect(File.readlines(path).first.chomp).to eq("/Am7:bonjour tout/A:")
    end

    it "une flèche valide aussi l'accord en cours de saisie, sans Entrée" do
      path = write_lyr(["bonjour tout"])
      simulate(path, "\nBm\e[C\r")
      expect(File.readlines(path).first.chomp).to include("/Bm:bonjour")
    end

    it "1 seule lettre reprend l'accord existant même s'il a plusieurs caractères (bug 2026-08-26, \"La chanson des vieux amants\" : \"b\" -> \"Bdim\" n'écrivait plus rien)" do
      path = write_lyr(["/Bdim:bonjour tout"])
      # "Bdim" déjà enregistré (lu depuis le fichier) => pas de question initiale.
      simulate(path, "Lb\r\r")
      expect(File.readlines(path).first.chomp).to eq("/Bdim:bonjour tout/Bdim:")
    end

    it "n/p avancent/reculent lettre par lettre (remplace Alt/Ctrl+flèche, abandonnés)" do
      path = write_lyr(["bonjour tout"])
      # 3x "n" : "b","o","n" -> curseur en position 3 ("bon|jour tout") ; 1x "p" -> 2.
      simulate(path, "\nnnnpGm\r\r")
      expect(File.readlines(path).first.chomp).to eq("bo/Gm:njour tout")
    end

    it "lettre minuscule puis chiffre : si la combinaison n'existe pas, FORCÉMENT un nouvel accord (bug 2026-08-26 : 'f'+'7' plaçait F puis ignorait le 7)" do
      path = write_lyr(["/F:bonjour tout"])
      # "F" déjà enregistré (letters["f"] = ["F"]) => pas de question initiale. Curseur
      # déplacé en fin de vers (L) ; "f" place "F" tout de suite (raccourci connu) ;
      # "7" : "F7" n'existe pas => annule le "F" posé, reprend en saisie "F7".
      simulate(path, "Lf7\r\r")
      expect(File.readlines(path).first.chomp).to eq("/F:bonjour tout/F7:")
    end

    it "lettre minuscule puis chiffre : si la combinaison existe déjà, corrige vers cet accord (pas un nouveau)" do
      path = write_lyr(["/F:bon /F7:jour tout"])
      # "F" et "F7" déjà enregistrés (dans cet ordre de rencontre) => pas de question
      # initiale. "f" place "F" (1er de la liste) en fin de vers, "7" corrige vers "F7"
      # (déjà connu) au lieu de forcer un nouvel accord.
      simulate(path, "Lf7\r\r")
      expect(File.readlines(path).first.chomp).to eq("/F:bon /F7:jour tout/F7:")
    end

    it "x (minuscule) supprime seulement l'accord au curseur" do
      path = write_lyr(["/Am:bonjour /C:tout"])
      simulate(path, "x\r")
      expect(File.readlines(path).first.chomp).to eq("bonjour /C:tout")
    end

    it "X (majuscule), confirmée, supprime TOUS les accords de la chanson" do
      path = write_lyr(["/Am:bonjour /C:tout", "/G:le monde"])
      simulate(path, "X\r", confirm: true)
      expect(File.readlines(path).map(&:chomp)).to eq(["bonjour tout", "le monde"])
    end

    it "X (majuscule), refusée, ne touche à AUCUN accord" do
      path = write_lyr(["/Am:bonjour /C:tout"])
      original = File.read(path)
      simulate(path, "X\r", confirm: false)
      expect(File.read(path)).to eq(original)
    end

    it "X sans aucun accord dans la chanson : ne demande rien, ne casse rien" do
      path = write_lyr(["bonjour tout"])
      simulate(path, "\nX\r", confirm: true)
      expect(File.readlines(path).first.chomp).to eq("bonjour tout")
    end

    it "chiffre du PAVÉ NUMÉRIQUE en cours de saisie (bug 2026-08-26, le vrai coupable : pavé inutilisable)" do
      path = write_lyr(["bonjour tout"])
      # "F" (nouvel accord) puis "7" via le pavé numérique (\eOw, DECKPAM) au lieu du
      # clavier normal.
      simulate(path, "\nF\eOw\r\r")
      expect(File.readlines(path).first.chomp).to eq("/F7:bonjour tout")
    end

    it "chiffre AZERTY sans Maj (\"è\" = 7) en cours de saisie" do
      path = write_lyr(["bonjour tout"])
      simulate(path, "\nFè\r\r")
      expect(File.readlines(path).first.chomp).to eq("/F7:bonjour tout")
    end

    it "une touche-commande (n/p/x/X/J/L/T/V) interrompt aussi la saisie en cours, comme une flèche" do
      path = write_lyr(["bonjour tout"])
      # "Gm" tapé, puis "n" (touche-commande) : valide "Gm" ET avance d'une lettre.
      simulate(path, "\nGmn\r")
      expect(File.readlines(path).first.chomp).to include("/Gm:")
    end
  end
end
