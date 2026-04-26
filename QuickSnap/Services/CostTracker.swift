import Foundation
import SwiftUI

/// Tracks API call costs across the processing pipeline.
@MainActor
final class CostTracker: ObservableObject {
    struct APICallRecord: Identifiable {
        let id = UUID()
        let model: String
        let inputTokens: Int
        let outputTokens: Int
        let timestamp: Date
        let stage: String
    }

    @Published var calls: [APICallRecord] = []
    @Published var totalInputTokens: Int = 0
    @Published var totalOutputTokens: Int = 0

    // Pricing per 1M tokens (USD)
    private let pricing: [String: (input: Double, output: Double)] = [
        "claude-haiku-4-5":          (input: 0.80,  output: 4.00),
        "claude-sonnet-4-5":          (input: 3.00,  output: 15.00),
        "claude-opus-4-6":           (input: 15.00, output: 75.00),
    ]

    func record(model: String, inputTokens: Int, outputTokens: Int, stage: String) {
        let call = APICallRecord(
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            timestamp: Date(),
            stage: stage
        )
        calls.append(call)
        totalInputTokens += inputTokens
        totalOutputTokens += outputTokens
    }

    var estimatedCostUSD: Double {
        var total = 0.0
        for call in calls {
            let rates = pricing[call.model] ?? (input: 3.0, output: 15.0)
            total += Double(call.inputTokens) / 1_000_000 * rates.input
            total += Double(call.outputTokens) / 1_000_000 * rates.output
        }
        return total
    }

    var formattedCost: String {
        String(format: "$%.2f", estimatedCostUSD)
    }

    var perModelBreakdown: [(model: String, inputTokens: Int, outputTokens: Int, cost: Double)] {
        var byModel: [String: (input: Int, output: Int)] = [:]
        for call in calls {
            let existing = byModel[call.model] ?? (0, 0)
            byModel[call.model] = (existing.0 + call.inputTokens, existing.1 + call.outputTokens)
        }
        return byModel.map { model, tokens in
            let rates = pricing[model] ?? (input: 3.0, output: 15.0)
            let cost = Double(tokens.input) / 1_000_000 * rates.input
                     + Double(tokens.output) / 1_000_000 * rates.output
            return (model, tokens.input, tokens.output, cost)
        }.sorted { $0.cost > $1.cost }
    }
}
