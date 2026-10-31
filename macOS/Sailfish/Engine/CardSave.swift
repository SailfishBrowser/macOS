import EngineCore

// A card Chrome offers to save, waiting on its toast.
struct PendingCard: Equatable, Identifiable, Sendable {
  let id: UUID
  let network: String
  let lastFourDigits: String
  let isSecurityCodeOnly: Bool
}

extension Engine {
  // A card submitted in a Chromium tab: its window's toast offers to save it, and Chrome saves it on Save.
  @objc(webContents:offersToSaveCard:completionHandler:)
  func webContents(
    _ contents: ECWebContents, offersToSaveCard card: ECCardOffer,
    completionHandler: @escaping (ECCardOfferAnswer) -> Void
  ) {
    guard let tab = tab(of: contents), !incognitoTabs.contains(tab) else { return completionHandler(.ignore) }
    let pending = PendingCard(
      id: UUID(), network: card.network, lastFourDigits: card.lastFourDigits,
      isSecurityCodeOnly: card.isSecurityCodeOnly)
    cardOffers[pending.id] = (tab, completionHandler)
    Self.continuation.yield(.cardOffered(tab: tab, card: pending))
  }

  func answerCard(_ id: PendingCard.ID, _ answer: ECCardOfferAnswer) {
    cardOffers.removeValue(forKey: id)?.answer(answer)
  }

  // A closing tab's offers end unanswered, and their toasts go.
  func withdrawCards(of tab: UUID) {
    for (id, offer) in cardOffers where offer.tab == tab {
      cardOffers[id] = nil
      offer.answer(.ignore)
      Self.continuation.yield(.cardWithdrawn(id))
    }
  }
}
