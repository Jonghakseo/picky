//
//  PickyHUDDockSessionPolicy.swift
//  Picky
//
//  Session-level presentation decisions shared by dock and conversation UI.
//

extension PickySessionListViewModel.SessionCard {
    var canRequestDockCompaction: Bool {
        guard !isCompacting else { return false }
        switch status {
        case .completed, .blocked, .failed, .cancelled:
            return true
        case .queued, .running, .waiting_for_input:
            return false
        }
    }
}
