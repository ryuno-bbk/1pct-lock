//
//  HomeViewModel.swift
//  AppBlocker
//
//  Business logic of the home screen
//

import Foundation
import Combine
import SwiftUI

final class HomeViewModel: ObservableObject {

    // MARK: - Published Properties

    @Published var currentQuote: Quote?
    @Published var backgroundStyle: BackgroundStyle = .solidBlack
    @Published var textSize: QuoteTextSize = .large

    // MARK: - Dependencies

    private var quoteService: QuoteService!
    private var storage: AppGroupStorage!

    // MARK: - Init

    @MainActor
    init() {
        self.quoteService = QuoteService.shared
        self.storage = AppGroupStorage.shared

        loadInitialData()
    }

    // MARK: - Public Methods

    /// Load initial data
    @MainActor
    func loadInitialData() {
        currentQuote = quoteService.currentQuote ?? Quote.samples.first

        let settings = storage.getSettings()
        backgroundStyle = settings.backgroundStyle
        textSize = settings.quoteTextSize

        if let quote = currentQuote {
            storage.saveCurrentQuote(SharedQuote(from: quote))
        }
    }

    /// Shuffle the quote
    func shuffleQuote() {
        quoteService.shuffleQuote()
        currentQuote = quoteService.currentQuote

        if let quote = currentQuote {
            storage.saveCurrentQuote(SharedQuote(from: quote))
        }
    }

    /// Select a quote
    func selectQuote(_ quote: Quote) {
        currentQuote = quote
        quoteService.selectQuote(quote)
        storage.saveCurrentQuote(SharedQuote(from: quote))
    }
}
