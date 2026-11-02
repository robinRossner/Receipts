package com.robinrossner.receipts.data

import com.robinrossner.receipts.data.api.PushEntity
import com.robinrossner.receipts.data.api.PushRequest
import com.robinrossner.receipts.data.api.PushResult
import com.robinrossner.receipts.data.api.PushStatus
import com.robinrossner.receipts.data.api.PullResponse
import com.robinrossner.receipts.data.api.WireDictionaryEntry
import com.robinrossner.receipts.data.api.WireJson
import com.robinrossner.receipts.data.api.WireTaxonomyAddition
import com.robinrossner.receipts.data.db.DictionaryEntity
import com.robinrossner.receipts.data.sync.toEntity
import com.robinrossner.receipts.data.sync.toWire
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The flag fields and the taxonomy additions on the wire: absent means "no statement", sent means the server obeys. */
class WireTest {
    private val json = WireJson.json
    private val pets = TaxonomyPath("Household", "Pets", "Pet Food")

    private val oldJson = """
        {"id": "0625a3cf-1f76-4ece-982c-8ce3214be232", "canonical_name": "bio eier", "aliases": [], "is_manual_override": false,
         "needs_review": false, "updated_at": "2026-10-31T12:30:00.000Z"}
    """.trimIndent()

    @Test
    fun oldPayloadsDecodeAndTheNewFieldsStayOffTheWireWhenUnset() {
        val e = json.decodeFromString<WireDictionaryEntry>(oldJson)
        assertNull(e.categoryFlagged); assertNull(e.suggestedCategory); assertNull(e.suggestedParent)
        val encoded = json.encodeToString(e)
        assertFalse("an entry that knows nothing about the flag does not send it", encoded.contains("category_flagged"))
        assertFalse(encoded.contains("suggested_"))
        // null (a JSON null from some server) counts as absent, too
        assertNull(json.decodeFromString<WireDictionaryEntry>(oldJson.replace("\"aliases\"", "\"category_flagged\": null, \"aliases\"")).categoryFlagged)
    }

    @Test
    fun aFlaggedEntryEncodesTheFlagAndItsSuggestions() {
        val flagged = json.decodeFromString<WireDictionaryEntry>(oldJson).copy(categoryFlagged = true, suggestedCategory = "Pet Food", suggestedParent = "Household")
        val text = json.encodeToString(flagged)
        assertTrue(text.contains("\"category_flagged\":true"))
        assertTrue(text.contains("\"suggested_parent\":\"Household\""))
        assertTrue(text.contains("\"suggested_category\":\"Pet Food\""))
        // forPush keeps them: the phone writes the flag, too
        assertEquals(true, flagged.forPush().categoryFlagged)
        assertEquals("Household", flagged.forPush().suggestedParent)
    }

    @Test
    fun theEntityAlwaysStatesTheFlagOnPushAndSuggestionsOnlyWhileFlagged() {
        val base = DictionaryEntity(uuid = "d1", canonicalName = "x", updatedAt = "2026-01-01T00:00:00.000Z")
        // "keep it in Other > Miscellaneous > General" does not change the category: only an explicit false resolves the flag
        val resolved = json.encodeToString(base.copy(suggestedCategory = "stale", suggestedParent = "stale").toWire().forPush())
        val obj = json.parseToJsonElement(resolved).jsonObject
        assertEquals(false, obj["category_flagged"]!!.jsonPrimitive.boolean)
        assertFalse("suggestions are not sent unflagged", obj.containsKey("suggested_category") || obj.containsKey("suggested_parent"))
        val flagged = json.parseToJsonElement(json.encodeToString(base.copy(categoryFlagged = true, suggestedCategory = "Pet Food", suggestedParent = "Household").toWire().forPush())).jsonObject
        assertEquals(true, flagged["category_flagged"]!!.jsonPrimitive.boolean)
        assertEquals("Pet Food", flagged["suggested_category"]!!.jsonPrimitive.content)
    }

    @Test
    fun aPushWithoutAdditionsHasNoAdditionsKeyAndIsEmpty() {
        val empty = PushRequest("x")
        assertFalse(json.encodeToString(empty).contains("taxonomy_additions"))
        assertTrue(empty.isEmpty)
        val withAdditions = PushRequest("x", taxonomyAdditions = listOf(WireTaxonomyAddition("Household", "Pets", "Pet Food", "2026-10-31T12:00:00.000Z")))
        assertFalse(withAdditions.isEmpty)
        val text = json.encodeToString(withAdditions)
        assertTrue(text, text.contains("\"taxonomy_additions\":[{\"category\":\"Household\",\"subcategory\":\"Pets\",\"item_group\":\"Pet Food\",\"created_at\":\"2026-10-31T12:00:00.000Z\"}]"))
    }

    @Test
    fun additionResultsAndPullsDecode() {
        val result = json.decodeFromString<PushResult>("""{"entity": "taxonomy_addition", "id": "A > B > C", "status": "applied"}""")
        assertEquals(PushEntity.TAXONOMY_ADDITION, result.entity)
        assertEquals(PushStatus.APPLIED, result.status)
        val old = json.decodeFromString<PullResponse>("""{"cursor": "c1", "has_more": false, "dictionary": [], "receipts": [], "line_items": []}""")
        assertNull("a server without the feature sends no list", old.taxonomyAdditions)
        val new = json.decodeFromString<PullResponse>(
            """{"cursor": "c1", "has_more": false, "dictionary": [], "receipts": [], "line_items": [],
               "taxonomy_additions": [{"category": "Household", "subcategory": "Pets", "item_group": "Pet Food", "created_at": "2026-10-31T12:00:00.000Z"}]}""",
        )
        assertEquals(pets, new.taxonomyAdditions?.first()?.path)
        assertEquals("Household > Pets > Pet Food", new.taxonomyAdditions?.first()?.label)
    }

    @Test
    fun pulledFlagsReachTheEntity() {
        val flagged = json.decodeFromString<WireDictionaryEntry>(oldJson).copy(
            category = "Other", subcategory = "Miscellaneous", itemGroup = "General", categoryFlagged = true, suggestedCategory = "Pet Food", suggestedParent = "Household",
        )
        val e = flagged.toEntity()
        assertTrue(e.categoryFlagged); assertEquals("Pet Food", e.suggestedCategory); assertEquals("Household", e.suggestedParent)
        // an explicit false drops the suggestions; so does an unflagged record that carries stale ones
        val cleared = flagged.copy(categoryFlagged = false).toEntity()
        assertFalse(cleared.categoryFlagged); assertNull(cleared.suggestedCategory); assertNull(cleared.suggestedParent)
    }
}
