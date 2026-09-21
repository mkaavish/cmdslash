/// Classifies risk by action type, centrally — not something a tool can self-declare
/// (Docs/PLANNING.md §30). A tool that wants a lower risk tier than this assigns it doesn't get
/// one; this is the only place that decision is made.
enum RiskLevel {
    case low
    case medium
    case high
}

enum RiskClassifier {
    static func riskLevel(forTool name: String) -> RiskLevel {
        switch name {
        case "create_calendar_event":
            .medium
        case "delete_calendar_event":
            .high
        case "run_coding_agent":
            .high
        default:
            .low
        }
    }
}
