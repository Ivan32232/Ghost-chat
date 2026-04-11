package com.ghost.chat.features.contacts

import android.content.Context
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.ghost.chat.core.storage.ContactStore
import com.ghost.chat.core.storage.DatabaseService
import com.ghost.chat.core.storage.MessageStore
import com.ghost.chat.models.ChatMessage
import com.ghost.chat.models.Contact
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class ContactsViewModel(context: Context) : ViewModel() {

    private val db = DatabaseService.getInstance(context)
    private val contactStore = ContactStore(db)
    private val messageStore = MessageStore(db)
    val contacts = mutableStateListOf<Contact>()
    val lastMessages = mutableStateMapOf<String, ChatMessage>()   // contactId -> last message
    val unreadCounts = mutableStateMapOf<String, Int>()           // contactId -> unread count

    fun loadContacts() {
        viewModelScope.launch(Dispatchers.IO) {
            val loaded = contactStore.fetchAll()
            val previews = mutableMapOf<String, ChatMessage>()
            val counts = mutableMapOf<String, Int>()
            for (contact in loaded) {
                val cId = contact.id
                messageStore.fetchLastMessage(cId)?.let { previews[cId] = it }
                val count = messageStore.countUnread(cId)
                if (count > 0) counts[cId] = count
            }
            // Also load Saved Messages preview
            val savedId = com.ghost.chat.features.chat.ChatViewModel.SAVED_MESSAGES_CONTACT_ID
            messageStore.fetchLastMessage(savedId)?.let { previews[savedId] = it }
            withContext(Dispatchers.Main) {
                contacts.clear()
                contacts.addAll(loaded)
                lastMessages.clear()
                lastMessages.putAll(previews)
                unreadCounts.clear()
                unreadCounts.putAll(counts)
            }
        }
    }

    fun deleteContact(contact: Contact) {
        viewModelScope.launch(Dispatchers.IO) {
            messageStore.deleteForContact(contact.id)
            contactStore.delete(contact.id)
            withContext(Dispatchers.Main) {
                contacts.remove(contact)
                lastMessages.remove(contact.id)
                unreadCounts.remove(contact.id)
            }
        }
    }

    fun updateLabel(contact: Contact, newLabel: String) {
        viewModelScope.launch(Dispatchers.IO) {
            contactStore.updateLabel(contact.id, newLabel)
            withContext(Dispatchers.Main) {
                val index = contacts.indexOfFirst { it.id == contact.id }
                if (index >= 0) {
                    contacts[index] = contacts[index].copy(label = newLabel)
                }
            }
        }
    }

    fun updateNotes(contact: Contact, notes: String?) {
        viewModelScope.launch(Dispatchers.IO) {
            contactStore.updateNotes(contact.id, notes)
            withContext(Dispatchers.Main) {
                val index = contacts.indexOfFirst { it.id == contact.id }
                if (index >= 0) {
                    contacts[index] = contacts[index].copy(notes = if (notes.isNullOrBlank()) null else notes)
                }
            }
        }
    }

    fun updateMessageTTL(contact: Contact, ttl: Int?) {
        viewModelScope.launch(Dispatchers.IO) {
            contactStore.updateMessageTTL(contact.id, ttl)
            withContext(Dispatchers.Main) {
                val index = contacts.indexOfFirst { it.id == contact.id }
                if (index >= 0) {
                    contacts[index] = contacts[index].copy(messageTTL = ttl)
                }
            }
        }
    }

    fun deleteHistory(contact: Contact) {
        viewModelScope.launch(Dispatchers.IO) {
            messageStore.deleteForContact(contact.id)
            withContext(Dispatchers.Main) {
                lastMessages.remove(contact.id)
                unreadCounts.remove(contact.id)
            }
        }
    }
}
