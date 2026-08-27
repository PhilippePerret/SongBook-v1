# frozen_string_literal: true

# Couleurs ANSI partagées entre les assistants interactifs — évite qu'un même bleu
# (#00b9ff, Phil) soit redéfini ailleurs sous une autre forme.
module AnsiColors
  BLUE = "\e[38;2;0;185;255m"
  SUCCESS = "\e[32m"
  ERROR = "\e[31m"
  GRAY = "\e[90m"
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
end
