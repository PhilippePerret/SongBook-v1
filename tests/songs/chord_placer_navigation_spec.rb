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

    it "basse seule (\"[fd]\") : jamais de diagramme dédié, jamais signalé" do
      expect(ChordPlacer.chord_known?("[fd]", Dir.mktmpdir)).to be true
    end
  end

  describe "ChordPlacer.capitalize_chord (basse entre crochets : 1re lettre capitale, issue #60)" do
    it "basse seule : capitale forcée, même tapée en minuscule" do
      expect(ChordPlacer.capitalize_chord("[fd]")).to eq("[Fd]")
    end

    it "basse bémol, même règle" do
      expect(ChordPlacer.capitalize_chord("[bb]")).to eq("[Bb]") # "bb" = si BÉMOL (2e "b" = suffixe bémol)
    end

    it "accord normal (sans crochets) : comportement inchangé" do
      expect(ChordPlacer.capitalize_chord("am7")).to eq("Am7")
    end
  end

  describe "ChordPlacer.typed_match (accord existant vs nouvel accord, refait à chaque frappe)" do
    it "minuscule initiale, correspond à un accord connu => ce nom exact" do
      letters = { "a" => ["A"] }
      expect(ChordPlacer.typed_match("a", letters, letters)).to eq("A")
    end

    it "minuscule initiale, ne correspond à rien de connu => nil (nouvel accord)" do
      expect(ChordPlacer.typed_match("d", {}, {})).to be_nil
    end

    it "MAJUSCULE initiale => jamais de correspondance, même si ça matcherait en minuscule" do
      letters = { "a" => ["A"] }
      expect(ChordPlacer.typed_match("A", letters, letters)).to be_nil
    end

    it "se raffine à chaque caractère : 'f' matche 'F', 'f7' ne matche plus rien" do
      letters = { "f" => ["F"] }
      expect(ChordPlacer.typed_match("f", letters, letters)).to eq("F")
      expect(ChordPlacer.typed_match("f7", letters, letters)).to be_nil
    end

    it "'f7' matche si 'F7' est déjà connu de cette lettre" do
      letters = { "f" => %w[F F7] }
      expect(ChordPlacer.typed_match("f7", letters, letters)).to eq("F7")
    end

    it "1 SEULE lettre = raccourci immédiat même si le nom de l'accord fait plusieurs caractères (bug 2026-08-26 : 'b' -> 'Bdim' n'écrivait plus rien, exigeait un match EXACT)" do
      letters = { "b" => ["Bdim"] }
      expect(ChordPlacer.typed_match("b", letters, letters)).to eq("Bdim")
    end

    it "1 seule lettre : reprend le PREMIER accord de cette lettre (ordre de rencontre)" do
      letters = { "a" => %w[Am7 A A7] }
      expect(ChordPlacer.typed_match("a", letters, letters)).to eq("Am7")
    end

    it "'b2' = 2e accord de la lettre 'b' par INDEX (légende 'b2 = ...', bug 2026-08-26 : laissé tel quel)" do
      letters = { "b" => %w[Bdim Bm9b] }
      expect(ChordPlacer.typed_match("b2", letters, letters)).to eq("Bm9b")
    end

    it "'b9' = index hors bucket => nil (nouvel accord)" do
      letters = { "b" => %w[Bdim Bm9b] }
      expect(ChordPlacer.typed_match("b9", letters, letters)).to be_nil
    end

    it "l'INDEX gagne même si un accord inutilisé porte littéralement le nom tapé (bug 2026-08-27 : un résidu 'B2' en cache volait le raccourci de position 'b2')" do
      letters = { "b" => %w[B7dim[d]-5 Bdim Bb Bbm B7dim B Bc B2 B3] }
      expect(ChordPlacer.typed_match("b2", letters, letters)).to eq("Bdim")
    end
  end

  describe "ChordPlacer.active_letters (légende affichée = accords ACTIVEMENT posés)" do
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

  describe "ChordPlacer.normalize_digit (un chiffre est un chiffre)" do
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
      captured = StringIO.new
      $stdin = StringIO.new(input)
      $stdout = captured
      allow(ChordPlacer).to receive(:with_raw_terminal).and_yield
      allow_any_instance_of(TTY::Prompt).to receive(:yes?).and_return(confirm)
      ChordPlacer.run(path)
      captured.string
    ensure
      $stdin = original_stdin
      $stdout = original_stdout
    end

    it "J ramène le curseur en tête du vers courant (remplace l'ancien raccourci A)" do
      path = write_lyr(["bonjour tout", "le monde"])
      # Flèche droite (déplace le curseur) ; J (retour en tête) ; "A" (nouvel accord) ;
      # Entrée (valide l'accord) ; Entrée (quitte l'assistant).
      simulate(path, "\e[CJA\r\r")
      expect(File.readlines(path).first.chomp).to eq("/A:bonjour tout")
    end

    it "L ramène le curseur en fin du vers courant (remplace l'ancien raccourci Z)" do
      path = write_lyr(["bonjour tout", "le monde"])
      simulate(path, "LG\r\r")
      expect(File.readlines(path).first.chomp).to eq("bonjour tout/G:")
    end

    it "\"[\" démarre la saisie d'une basse SEULE (\"[Fd]\", 1re lettre capitale, issue #60)" do
      path = write_lyr(["bonjour tout"])
      simulate(path, "L[FD]\r\r") # tapé en MAJUSCULE : reste capitale sur la 1re lettre, minuscule ensuite
      expect(File.readlines(path).first.chomp).to eq("bonjour tout/[Fd]:")
    end

    it "une MAJUSCULE force un nouvel accord malgré la collision avec un raccourci connu" do
      path = write_lyr(["/Am7:bonjour tout"])
      # "a" déjà enregistré (Am7, lu depuis le fichier) => pas de question initiale.
      simulate(path, "LA\r\r")
      expect(File.readlines(path).first.chomp).to eq("/Am7:bonjour tout/A:")
    end

    it "une flèche valide aussi l'accord en cours de saisie, sans Entrée" do
      path = write_lyr(["bonjour tout"])
      simulate(path, "Bm\e[C\r")
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
      simulate(path, "nnnpGm\r\r")
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

    it "\"/\" à froid (aucune saisie en cours) sur un accord déjà posé : ajoute un 2e accord, ne l'écrase pas" do
      path = write_lyr(["/G:bonjour tout"])
      simulate(path, "J/C\r\r")
      expect(File.readlines(path).first.chomp).to eq("/G://C:bonjour tout")
    end

    it "\"/\" à froid sans accord au curseur : commit normal, pas de fusion fantôme" do
      path = write_lyr(["bonjour tout"])
      simulate(path, "/C\r\r")
      expect(File.readlines(path).first.chomp).to eq("/C:bonjour tout")
    end

    it "\"/\" tapé en tout premier (sans accord au curseur) : l'aperçu affiche \"/\" puis \"/F\" IMMÉDIATEMENT (bug constaté : rien ne s'affichait tant qu'aucun accord n'existait déjà au curseur)" do
      path = write_lyr(["bonjour tout"])
      output = simulate(path, "/F\r\r").gsub(/\e\[[0-9;]*m/, "")
      expect(output).to match(%r{(?<![A-Za-z/])/(?![A-Za-z])})
      expect(output).to match(%r{(?<![A-Za-z/])/F(?![A-Za-z])})
    end

    it "\"x\" pendant une saisie en cours ANNULE la saisie et supprime l'accord au curseur (jamais ajouté au nom, bug constaté : \"xx~xx\" écrit littéralement)" do
      path = write_lyr(["/F:bonjour tout"])
      simulate(path, "JFxxx\r")
      expect(File.readlines(path).first.chomp).to eq("bonjour tout")
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
      simulate(path, "X\r", confirm: true)
      expect(File.readlines(path).first.chomp).to eq("bonjour tout")
    end

    it "chiffre du PAVÉ NUMÉRIQUE en cours de saisie (bug 2026-08-26, le vrai coupable : pavé inutilisable)" do
      path = write_lyr(["bonjour tout"])
      # "F" (nouvel accord) puis "7" via le pavé numérique (\eOw, DECKPAM) au lieu du
      # clavier normal.
      simulate(path, "F\eOw\r\r")
      expect(File.readlines(path).first.chomp).to eq("/F7:bonjour tout")
    end

    it "chiffre AZERTY sans Maj (\"è\" = 7) en cours de saisie" do
      path = write_lyr(["bonjour tout"])
      simulate(path, "Fè\r\r")
      expect(File.readlines(path).first.chomp).to eq("/F7:bonjour tout")
    end

    it "une touche-commande MAJUSCULE (X/J/L/T/V) interrompt aussi la saisie en cours, comme une flèche" do
      path = write_lyr(["bonjour tout"])
      # "Gm" tapé, puis "L" (touche-commande) : valide "Gm" ET va en fin de vers.
      simulate(path, "GmL\r")
      expect(File.readlines(path).first.chomp).to include("/Gm:")
    end

    it "\"n\"/\"p\"/\"x\" (minuscules) N'interrompent PLUS la saisie, s'ajoutent au nom (issue #62, \"Gsus4-3p\" tronqué à \"Gsus4-3\")" do
      path = write_lyr(["bonjour tout"])
      simulate(path, "Gsus4-3p\r\r")
      expect(File.readlines(path).first.chomp).to eq("/Gsus4-3p:bonjour tout")
    end

    it "\"/\" en cours de saisie valide l'accord ET en démarre un 2e à la même position (issue #66, \"G/C\" ne doit JAMAIS être un seul accord nommé \"G/C\")" do
      path = write_lyr(["bonjour tout"])
      simulate(path, "G/C\r\r")
      expect(File.readlines(path).first.chomp).to eq("/G://C:bonjour tout")
    end

    it "\"/\" en cours de saisie : l'aperçu live affiche \"1er/\" puis \"1er/2e\", jamais le 1er accord remplacé/masqué par le 2e (bug constaté : le \"/\" ne s'affichait JAMAIS à l'écran)" do
      path = write_lyr(["bonjour tout"])
      output = simulate(path, "F/C\r\r").gsub(/\e\[[0-9;]*m/, "")
      expect(output).to match(%r{(?<![A-Za-z/])F/(?![A-Za-z])})
      expect(output).to include("F/C")
    end

    it "\"/\" à froid : abandonné dès qu'on navigue sans taper de 2e accord (bug constaté : le \"/\" en aperçu SUIVAIT le curseur partout, même sans intention de fusion)" do
      path = write_lyr(["bonjour tout"])
      output = simulate(path, "/\e[C\e[C\e[C\r").gsub(/\e\[[0-9;]*m/, "")
      frames = output.split("\e[2J\e[H")
      chord_row = frames.last.lines[3]
      expect(chord_row).not_to include("/")
    end

    it "\"/\" tapé juste après un accord dont le nom finit pile à la position du curseur : s'écrit COLLÉ, pas 1 colonne plus loin (bug constaté : la marge de l'issue #67 poussait le \"/\" au-delà de la vraie position du curseur)" do
      path = write_lyr(["/Bm7:bonjour tout"])
      output = simulate(path, "J\e[C/\r\r").gsub(/\e\[[0-9;]*m/, "")
      expect(output).to include("Bm7/")
      expect(output).not_to include("Bm7 /")
    end

    it "\"/\" tapé en TOUT bout de ligne : le curseur en surbrillance reste visible, jamais une case vide hors du tableau affiché (bug constaté : le curseur disparaissait complètement à l'écran)" do
      path = write_lyr(["bonjour"])
      output = simulate(path, "L/\r\r")
      expect(output).not_to match(/\e\[7m\e\[0m/)
    end
  end

  describe "ChordLine.split_for_write (\"/\" = TOUJOURS deux accords distincts, issue #66)" do
    it "\"Bb6/C\" n'est plus un accord composé : 2 accords" do
      expect(ChordLine.split_for_write("Bb6/C")).to eq(%w[Bb6 C])
    end

    it "accord simple, sans \"/\" : inchangé" do
      expect(ChordLine.split_for_write("Am7")).to eq(["Am7"])
    end
  end

  describe "ChordLine#chord_tokens (2 accords à la même position -> double slash, issue #64/#66)" do
    it "\"/G://C:\" (double slash), jamais \"/G:/C:\" (le \"/\" simple ne laisse rien à reconnaître comme séparateur dans le PDF, Layout.chords_only_steps)" do
      line = ChordLine.new("bonjour", { 0 => "G/C" })
      expect(line.chord_tokens(0)).to eq("/G://C:")
    end
  end

  describe "ChordPlacer.render_line (le \"/\" séparateur rejoint la ligne des accords, jamais celle des paroles, issue #64)" do
    it "accords séparés par du texte réel (\"/G:_ //Bm:_\", \"Nikita\") : \"/\" sur la ligne accords" do
      line = ChordLine.parse("/G:_ //Bm:_")
      expect { ChordPlacer.render_line(line, nil) }.to output("G /Bm\n_  _\n").to_stdout
    end

    it "accords collés en tête d'un vers normal (\"/G://C:bonjour\", issue #66) : \"/\" jamais dans la parole" do
      line = ChordLine.parse("/G://C:bonjour")
      expect { ChordPlacer.render_line(line, nil) }.to output(/\n[^\n\/]*bonjour\n\z/).to_stdout
    end

    it "ligne 100% accords, offsets collés (intro \"Mother Nature's Son\", issue #67) : chaque accord lisible, jamais écrasé par le suivant" do
      line = ChordLine.parse("/D: /Dsus4: /D2://Dsus4://D: /D2://D: /D2://D:")
      expect { ChordPlacer.render_line(line, nil) }.to output(/\AD Dsus4 D2\/Dsus4\/D D2\/D D2\/D\n/).to_stdout
    end
  end
end
