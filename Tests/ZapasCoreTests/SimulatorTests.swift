import Foundation
import Testing
@testable import ZapasCore

private let deviceID = "11111111-1111-4111-8111-111111111111"
private let otherID = "22222222-2222-4222-8222-222222222222"
private let missingID = "33333333-3333-4333-8333-333333333333"

private func deviceJSON() -> Data {
    Data("""
    {"devices": {
      "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
        {"name":"Generic Booted","udid":"\(deviceID)","state":"Booted","isAvailable":true,"dataPath":"/fixture/device/data"},
        {"name":"Unavailable","udid":"\(missingID)","state":"Shutdown","isAvailable":false}],
      "com.apple.CoreSimulator.SimRuntime.tvOS-27-0": [
        {"name":"TV","udid":"\(otherID)","state":"Booted","isAvailable":true}]
    }}
    """.utf8)
}

@Test func mixedRuntimeInventoryAndExplicitAssignment() throws {
    let list = try SimulatorInventory.decode(deviceJSON())
    #expect(list.totalDeviceCount == 3)
    #expect(list.devices.filter(\.isIOS).count == 2)
    let booted = try #require(list.devices.first { $0.udid == deviceID })
    #expect(booted.assignment == "unknown_or_other_project")
    #expect(throws: ProbeIssue.self) { try SimulatorInventory.requireAssignedIOS(booted) }
    let assigned = try SimulatorInventory.decode(deviceJSON(), assignedUDIDs: [deviceID, otherID, missingID])
    try SimulatorInventory.requireAssignedIOS(try #require(assigned.devices.first { $0.udid == deviceID }))
    for device in assigned.devices where !device.isIOS || !device.isAvailable {
        #expect(throws: ProbeIssue.self) { try SimulatorInventory.requireAssignedIOS(device) }
    }
}

@Test func associationsRequireConcreteDevicePath() throws {
    let list = try SimulatorInventory.decode(deviceJSON())
    #expect(SimulatorInventory.associations(path: "/fixture/device/data/Containers/App/Test", devices: list.devices) == [deviceID])
    #expect(SimulatorInventory.associations(path: "/fixture/device/data-other/Test", devices: list.devices).isEmpty)
    #expect(SimulatorInventory.associations(path: "/Applications/Simulator.app", devices: list.devices).isEmpty)
    #expect(SimulatorInventory.associations(path: nil, devices: list.devices).isEmpty)
}

@Test func malformedSimulatorInputIsNotAnEmptyInventory() {
    #expect(throws: (any Error).self) { try SimulatorInventory.decode(Data("{}".utf8)) }
    #expect(throws: (any Error).self) { try SimulatorInventory.decode(Data("permission denied".utf8)) }
    #expect(throws: (any Error).self) { try SimulatorInventory.decode(Data("{\"devices\": {\"iOS\": [{\"name\":\"Bad\",\"udid\":\"oops\",\"state\":\"Booted\",\"isAvailable\":true}]}}".utf8)) }
}
