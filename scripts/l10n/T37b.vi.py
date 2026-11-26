PREFIXES = ("apps.quit.",)

VI = {
    "apps.quit.button": "Thoát ứng dụng",
    "apps.quit.help": "Yêu cầu ứng dụng thoát, giống như ⌘Q. Ứng dụng có thể hỏi bạn lưu trước.",
    "apps.quit.quitting": "Đang thoát…",
    "apps.quit.stuck": "%@ vẫn đang mở. Có thể ứng dụng đang hỏi bạn lưu — hãy chuyển sang ứng dụng, hoặc buộc thoát.",
    "apps.quit.show": "Chuyển sang ứng dụng",
    "apps.quit.force": "Buộc thoát…",
    "apps.quit.confirm.title": "Buộc thoát %@?",
    "apps.quit.confirm.message": "Những thay đổi chưa lưu trong %@ sẽ bị mất. Chỉ dùng khi ứng dụng không phản hồi.",
    "apps.quit.confirm.action": "Buộc thoát",
    "apps.quit.confirm.cancel": "Hủy",
    "apps.quit.done": "%@ đã thoát. Giờ bạn có thể gỡ cài đặt.",
    "apps.quit.failed": "%@ chưa thoát được.",
    "apps.quit.relaunched": "%@ tự mở lại. Có thứ gì đó đang khởi động lại nó — hãy xem Mục khởi động.",
    "apps.quit.background": "Một tiến trình nền của %1$@ vẫn đang chạy: %2$@. Hãy khởi động lại máy, hoặc kết thúc nó trong Activity Monitor.",
    "apps.quit.otherUser": "%@ cũng đang chạy cho một người dùng khác trên máy này. Người đó cần thoát nó trước.",
    "apps.quit.unknown": "Không kiểm tra được %@ có đang chạy không. Chưa thoát ứng dụng nào.",
    "apps.quit.checkAgain": "Kiểm tra lại",
    "apps.quit.self": "AI Disk Keeper không thể tự thoát hay tự gỡ cài đặt từ đây.",
    "apps.quit.auditFailed": "Không ghi được vào nhật ký thao tác nên chưa buộc thoát ứng dụng nào.",
    "apps.quit.a11y.done": "%@ đã thoát",
}

# Plural keys (String Catalog `variations.plural`). Vietnamese has no plural forms, so only `other`.
PLURALS = {
    "apps.quit.confirm.instances": {
        "en": {"one": "%lld copy is running.", "other": "%lld copies are running."},
        "vi": {"other": "Đang có %lld bản chạy."},
    },
}
