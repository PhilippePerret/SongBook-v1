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

  describe "ChordPlacer.resolve_letter (accord existant vs nouvel accord)" do
    it "lettre inconnue => nouvel accord" do
      expect(ChordPlacer.resolve_letter("d", {})).to eq({ new: "d" })
    end

    it "lettre minuscule frappée sur raccourci connu => accord existant" do
      letters = { "a" => ["Am7"] }
      expect(ChordPlacer.resolve_letter("a", letters)).to eq({ existing: "Am7", letter: "a" })
    end

    it "même lettre frappée en MAJUSCULE force un nouvel accord (collision)" do
      letters = { "a" => ["Am7"] }
      expect(ChordPlacer.resolve_letter("A", letters)).to eq({ new: "A" })
    end

    it "touche non alphabétique => rien" do
      expect(ChordPlacer.resolve_letter("3", {})).to be_nil
      expect(ChordPlacer.resolve_letter(:enter, {})).to be_nil
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
  end
end
