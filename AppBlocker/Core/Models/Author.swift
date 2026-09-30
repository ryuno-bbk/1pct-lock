//
//  Author.swift
//  AppBlocker
//
//  Great figure (SNS account) model
//

import Foundation

/// Model that represents a great figure (great figure = SNS account)
struct Author: Identifiable, Codable, Equatable {
    let id: UUID
    let name: String
    let bioEn: String
    let bioJp: String
    let nationality: String
    let imageUrl: String?
    let isOfficial: Bool
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case bioEn = "bio_en"
        case bioJp = "bio_jp"
        case nationality
        case imageUrl = "image_url"
        case isOfficial = "is_official"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.bioEn = try c.decodeIfPresent(String.self, forKey: .bioEn) ?? ""
        self.bioJp = try c.decodeIfPresent(String.self, forKey: .bioJp) ?? ""
        self.nationality = try c.decodeIfPresent(String.self, forKey: .nationality) ?? ""
        self.imageUrl = try c.decodeIfPresent(String.self, forKey: .imageUrl)
        self.isOfficial = try c.decodeIfPresent(Bool.self, forKey: .isOfficial) ?? false
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    /// Returns the bio for the language
    func displayBio(lang: AppLanguage) -> String {
        switch lang {
        case .english:
            return bioEn.isEmpty ? bioJp : bioEn
        case .japanese:
            return bioJp.isEmpty ? bioEn : bioJp
        }
    }

    init(
        id: UUID = UUID(),
        name: String,
        bioEn: String = "",
        bioJp: String = "",
        nationality: String = "",
        imageUrl: String? = nil,
        isOfficial: Bool = false,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.bioEn = bioEn
        self.bioJp = bioJp
        self.nationality = nationality
        self.imageUrl = imageUrl
        self.isOfficial = isOfficial
        self.createdAt = createdAt
    }
}
