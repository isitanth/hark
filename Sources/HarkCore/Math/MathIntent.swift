import Foundation

// The word check, decision 4 (M13): a verbatim port of the frozen `docs/acceptance/M13-data/bench/wordcheck.py`
// (SHA-256 726464fe…, its tables f579caf1… and 02a7021a…, recorded in docs/acceptance/M13.md). Add, drop or reword
// nothing here: a word that seems missing goes to the lead.

public enum MathIntent {
    public static let computeEnglish: [String] = [
        "how much", "how many", "total", "totals", "in total", "altogether", "sum", "add up", "adds up", "average",
        "per year", "per month", "per week", "per day", "per kilo", "per kg", "per person", "per head", "split", "%",
        "percent", "percentage", "grow", "grew", "growth", "increase", "increased", "decrease", "decreased",
        "difference", "balance", "profit", "cheapest", "most expensive", "the most", "the least", "highest", "lowest",
        "largest", "smallest", "count", "number of", "come to", "comes to", "left to pay", "still to be", "owe",
        "tip", "discount", "tax", "vat", "divide", "multiply", "subtract", "exceed", "over budget", "under budget",
        "is the total right", "in euros", "in dollars", "biggest", "priciest", "did i spend", "have i spent",
        "did we spend", "have we spent", "add these", "add those", "add them", "add all", "add everything", "tally",
        "gap between", "installment", "installments", "instalment", "instalments", "unit price", "per unit",
        "per item", "per hour", "per kwh", "per kilowatt", "per litre", "per liter", "per quarter", "per night",
        "conversion rate", "works out to", "work out to", "calculate", "calculation", "compute", "minus", "subtotal",
    ]

    public static let computeFrench: [String] = [
        "combien", "total", "totale", "totaux", "au total", "somme", "additionne", "moyenne", "pourcentage", "%",
        "pour cent", "par personne", "par tete", "par mois", "par an", "par annee", "par semaine", "par jour",
        "au kilo", "par kilo", "au kg", "tva", "ttc", "ht", "solde", "reste a payer", "restant", "reste du",
        "le plus", "la plus", "le moins", "la moins", "moins cher", "moins chere", "plus cher", "plus chere",
        "difference", "ecart", "augmente", "augmentation", "baisse", "depasse", "depassement", "benefice", "marge",
        "nombre de", "compter", "calcule", "partage", "divise", "remise", "reduction", "pourboire", "en euros",
        "en tout", "plus gros", "plus grosse", "plus grand", "plus grande", "plus petit", "plus petite", "plus eleve",
        "plus elevee", "pourcent", "pourcents", "cumul", "cumule", "cumulee", "cumules", "cumulees", "ticket moyen",
        "panier moyen", "prix moyen", "montant moyen", "cout moyen", "taux moyen", "horaire moyen", "temps moyen",
        "additionner", "additionnes", "additionnez", "calculer", "calcules", "calculez", "le calcul", "diviser",
        "partager", "multiplie", "multiplier", "soustrais", "soustraire", "par heure", "par trimestre", "au litre",
        "par litre", "par kwh", "par nuit", "ce que j ai depense", "j ai depense quoi", "ce qu on a depense",
        "on a depense quoi",
    ]

    public static let fillers: [String] = [
        "en tout cas", "en tout etat de cause",
    ]

    public static let blockEnglish: [String] = [
        "translate", "translation", "rewrite", "rephrase", "reword", "summarize", "summarise", "proofread", "explain",
        "called", "say about", "says about", "does this say", "mean", "means", "stand for", "stands for",
        "in english", "in french", "most important", "most recent", "vat number", "tax id", "biggest risk",
        "biggest concern", "biggest problem", "biggest issue", "biggest challenge", "most urgent",
    ]

    public static let blockFrench: [String] = [
        "traduis", "traduire", "traduit", "traduction", "reformule", "reecris", "resume", "corrige", "explique",
        "s appelle", "comment dit on", "veut dire", "signifie", "en anglais", "en francais", "plus important",
        "plus importante", "plus recent", "plus recente", "numero de tva", "tva intracommunautaire",
        "plus gros risque", "plus grand risque", "plus gros probleme", "plus grand probleme", "plus grand defi",
        "plus gros defi", "plus urgent", "plus urgente",
    ]

    /// Whether the spoken instruction asks for a calculation, in English or French. False sends the framed ask down
    /// today's path. Both languages' lists apply whatever whisper's language says.
    public static func isComputation(_ instruction: String) -> Bool {
        var question = normalize(instruction)
        for filler in fillers {
            question = question.replacingOccurrences(of: normalize(filler), with: " ")
        }
        if hits(question, blockEnglish) || hits(question, blockFrench) { return false }
        return hits(question, computeEnglish) || hits(question, computeFrench)
    }

    /// NFD, combining marks dropped, lowercased; `%` stands alone, every other character that is not a letter or a
    /// digit is a space; spaces collapsed, then one space padded at each end.
    static func normalize(_ text: String) -> String {
        let decomposed = text.decomposedStringWithCanonicalMapping.unicodeScalars.filter {
            $0.properties.canonicalCombiningClass == .notReordered
        }
        var out = ""
        for character in String(String.UnicodeScalarView(decomposed)).lowercased() {
            if character == "%" {
                out += " % "
            } else if character.isLetter || character.isNumber {
                out.append(character)
            } else {
                out += " "
            }
        }
        return " " + out.split(separator: " ").joined(separator: " ") + " "
    }

    static func hits(_ padded: String, _ phrases: [String]) -> Bool {
        phrases.contains { padded.contains(normalize($0)) }
    }
}
