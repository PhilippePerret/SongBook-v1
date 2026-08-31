# frozen_string_literal: true

require "tty-prompt"

# Couleurs ANSI partagées entre les assistants interactifs — évite qu'un même bleu
# (#00b9ff) soit redéfini ailleurs sous une autre forme.
module AnsiColors
  BLUE = "\e[38;2;0;185;255m"
  SUCCESS = "\e[32m"
  # Rouge ANSI standard (`\e[31m`) trop sombre à l'usage  — vrai rouge clair
  # (RGB), même forme truecolor que `BLUE`.
  ERROR = "\e[38;2;255;90;90m"
  GRAY = "\e[90m"
  # Couleur des items "hors liste" dans un picker (ex. "Terminé", "Nouveau carnet…",
  # jamais un contenu réel, une ACTION à part du contenu choisi.
  ORANGE = "\e[38;2;255;165;0m"
  RESET = "\e[0m"

  def blue(text)
    "#{BLUE}#{text}#{RESET}"
  end

  def success(text)
    "#{SUCCESS}#{text}#{RESET}"
  end

  def error(text)
    "#{ERROR}#{text}#{RESET}"
  end

  def gray(text)
    "#{GRAY}#{text}#{RESET}"
  end

  def orange(text)
    "#{ORANGE}#{text}#{RESET}"
  end

  # `TTY::Prompt.new` avec notre bleu comme couleur de l'item survolé 
  # — défaut de la gem `active_color: :green`, trompeur : le vert est réservé aux
  # messages de résultat/succès dans cette appli, `success`). À utiliser PARTOUT à la
  # place de `TTY::Prompt.new` nu.
  # Un `choice.name` peut déjà porter sa propre couleur (ex. `orange(...)`, item "hors
  # liste") — l'item survolé doit rester bleu malgré tout : la gem enveloppe TEL QUEL le
  # nom déjà coloré dans le bleu (`decorate`), ce qui imbrique les codes ANSI et fait
  # ressortir la couleur d'origine (le code couleur imbriqué l'emporte visuellement).
  # Nettoyée d'abord pour repartir d'un texte neutre.
  def colored_prompt
    TTY::Prompt.new(active_color: ->(s) { blue(s.gsub(/\e\[[\d;]*m/, "")) })
  end
end
