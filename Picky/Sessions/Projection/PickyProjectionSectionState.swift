//
//  PickyProjectionSectionState.swift
//  Picky
//

import Foundation

enum PickyProjectionSectionState<Value: Equatable>: Equatable {
    case unavailable
    case loaded(Value)
}
